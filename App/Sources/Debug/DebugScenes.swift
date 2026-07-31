#if DEBUG
import CoreLocation
import Foundation
import DesignSystem
import MyRoboTaxiKit
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
    /// MYR-341 — the rider IDLE sheet with the ROTATING placeholder carrying a
    /// REAL "A ride is N min away". Live-only by construction: the line needs a
    /// device fix, a watched-vehicle coordinate and an available live fleet
    /// member all at once, behind a real auth session, so a simulated boot can
    /// never reach it (and the simulated path deliberately keeps the fixture "3
    /// min" line, which is why `idle` stays byte-identical).
    ///
    /// Nothing about the number is hand-set: the scene seeds the two ENDPOINTS
    /// (a device fix through the existing MYR-248 `simulatedUserFix` hook, and a
    /// vehicle coordinate through `debugVehicleCoordinateOverride`) plus an
    /// available live-shaped `FleetMember` built by the REAL
    /// `LiveFleetMemberMapping`, then lets the shipping `RiderPickupETA`
    /// quantize, estimate and gate. The endpoints are ~2.8 mi apart, so the
    /// shipping closed form (× 1.3 detour ÷ 24 mph) renders "A ride is 9 min
    /// away".
    ///
    /// `RotatingPlaceholder` alternates on a 2800ms cadence, so capture at
    /// t≈1s for "Where to?" and t≈3.5s for the ETA line.
    case riderIdleETA
    /// MYR-341 — the SAME scene with the honesty gate tripped: identical rider
    /// fix and vehicle coordinate, but the car is BUSY (`hasActiveRide` through
    /// the real MYR-233 predicate). A perfectly computable straight line is
    /// still not an offer, so the placeholder falls back to the static "Where
    /// to?" and stops rotating. The pair is a clean before/after of exactly the
    /// availability gate.
    case riderIdleETABusy
    /// MYR-352 — the rider IDLE sheet carrying the muted "no rides" banner above
    /// the search bar, for a rider whose vehicle set is ONE unavailable car.
    ///
    /// Reuses `riderBusyVehicle`'s own `MRT_BUSY_REASON=busy|inService|offline|
    /// paused` selector and its live-shaped `busyFleetMember`, so all four
    /// headline variants AND both scheduling-line branches come out of ONE scene,
    /// built from real wire inputs through the REAL `LiveFleetMemberMapping` —
    /// the copy in the capture is what the shipping predicate produced, not a
    /// literal. `paused` is the variant with NO second line (§7.18 refuses
    /// scheduled rides too), and it is the pair's most load-bearing capture.
    ///
    /// Live-path-only by construction: every `FleetMember` fixture has
    /// `unavailability == nil` and `SharedViewerState.liveFleetMembers` is empty in
    /// SIM, so `idle` and every other rider scene are byte-identical.
    case riderNoRides
    /// MYR-352 — the same banner for a MULTI-vehicle set: two cars, out for two
    /// different reasons, so no single reason is true of the fleet and the headline
    /// is the client's generic "No rides available right now".
    ///
    /// It needs its own scene because a fleet is the one input
    /// `debugFleetMemberOverride` cannot express, and the vehicle COUNT is what
    /// selects the headline. One car is in service and one is offline — both of
    /// which still allow scheduling — so the second line is present here and the
    /// pair with `riderNoRides MRT_BUSY_REASON=paused` isolates exactly that line.
    case riderNoRidesFleet
    /// MYR-172 — the rider's ride LIVE ACTIVITY, started for real so the system can
    /// render it.
    ///
    /// The only scene whose subject is not drawn by this app at all: the lock-screen
    /// card and the Dynamic Island are rendered by the `MyRoboTaxiWidgets` process,
    /// so booting a screen and screenshotting it captures nothing. This scene starts
    /// a genuine Activity through the SHIPPING `SystemRideActivityPresenter` and
    /// then gets out of the way; the picture is of the system, not of the app.
    ///
    /// `MRT_ACTIVITY_STATE=enroute|accepted|arrived|completed|stale` selects which
    /// frame. `stale` is the honest-staleness arm and is seeded by handing
    /// ActivityKit a stale-date in the PAST — there is no API to force staleness, so
    /// the only way to photograph `context.isStale` is to actually be stale. Default
    /// `enroute`.
    ///
    /// It boots the ordinary rider `idle` shell underneath, so the app itself is in
    /// a known state and every other rider scene stays byte-identical.
    case riderLiveActivity
    /// MYR-356 — the SEARCH sheet's pre-typing region carrying the rider's own
    /// RECENT DESTINATIONS.
    ///
    /// It needs its own scene because recents live in `UserDefaults` and every
    /// other scene boots against an EMPTY in-memory store on purpose
    /// (`RootView.recentDestinationsStore()`): a persistent list is exactly the kind
    /// of state that would drift a byte-stable capture depending on whether anyone
    /// had driven the flow on that simulator. So `search`, `searchFiltered` and
    /// `searchSelected` stay byte-identical, and this one scene shows the feature.
    ///
    /// Nothing about the rendering is hand-set: the scene seeds SIX rows and the
    /// shipping `RecentDestinationList.capped` shows five, most-recent-first — so
    /// the capture is the cap and the ordering, proven rather than illustrated.
    ///
    /// It is `search` VERBATIM plus that one seeded store, so the pair is a clean
    /// before/after of exactly the Recent section: `search` shows the four
    /// prototype fixtures standing in for a history that did not exist, this shows
    /// the five real rows that take their place the moment one does. No live seams
    /// are forced — recents are device-local and therefore honest on BOTH paths,
    /// which is the whole point of the feature (on the live path the same rows are
    /// the entire pre-typing region, replacing "Type a destination to search").
    case riderRecentDestinations

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

    // MYR-355 → MYR-366 — account deletion (App Store Guideline 5.1.1(v)) and the
    // VISUAL OFFBOARDING FLOW that replaced its second dialog. All six are the
    // settings screens with the SHIPPING `AccountDeletionFlow` driven to one of
    // its states, because headless tooling can neither tap "Delete account" nor a
    // dialog button. They carry the same DEBUG identity `ownerSettings` /
    // `riderSettings` do (`showsLiveSettings`).
    //
    // **This family changed deliberately in MYR-366** (a client-directed
    // redesign): `ownerDeleteAccountConfirm` / `riderDeleteAccountConfirm` are
    // GONE with the second dialog they captured, and `deleteAccountFailed` is
    // superseded by `offboardingFailed`, which shows the same refusal on the
    // surface it now happens on. Everything outside this family is byte-identical.
    /// The OWNER's dialog: "Delete your account?" with the owner-role
    /// consequences (Tesla(s), everyone's access) + the permanence sentence.
    case ownerDeleteAccount
    /// The RIDER's dialog: the same title with the rider-role consequences
    /// (access to shared Teslas, requested rides). The two messages are the whole
    /// reason the copy is role-split, so both need a capture.
    case riderDeleteAccount
    /// MYR-366 — the STEPPER, mid-flight. Injects a `DELETE` that never answers
    /// (`DebugAccountDeletionEndpoint(hangs: true)`), which is the only way to
    /// hold either of its two in-flight frames still: against a real backend the
    /// call lands in milliseconds. Capture TWICE — at t≈1.4s for a narration
    /// part-way down the sequence, and at t≈5s for the honesty gate itself, the
    /// narration finished with the LAST step still spinning because no `204` has
    /// arrived. There is no other route to either frame.
    case ownerOffboarding
    /// MYR-366 — the FAILURE, on the surface it now happens on: a scripted `500`
    /// held 1.2s so the narration is genuinely part-way when it lands. The
    /// stepper STOPS where it stood — checks behind, nothing ahead, the failed
    /// phase's circle red — over MYR-355's locked notice and a "Try again" the
    /// re-runnable endpoint makes safe. Supersedes `deleteAccountFailed`.
    case offboardingFailed
    /// MYR-366 — the OWNER's ending, "Two steps only you can do". The simulated
    /// path's `nil` endpoint succeeds immediately, so the stepper completes on the
    /// narration's own clock and the ending crossfades in; capture at t≈4.5s. The
    /// two illustrations LOOP on a 3s period, so also capture a second frame ~1.5s
    /// later to show the key row gone and the toggle off.
    case ownerOffboardingDone
    /// MYR-366 — the RIDER's ending: the check-hero, and no manual steps, because
    /// a rider has none. Same timing as the owner's.
    case riderOffboardingDone

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
    // MARK: MYR-376/377 — the reservation lifecycle
    /// MYR-376 — owner Home holding an ACCEPTED RESERVATION FOR TOMORROW.
    ///
    /// THE PAIR'S OTHER HALF IS `ownerDispatched`, and the diff is the whole issue:
    /// the same accepted record, the same owner Home, and NO DISPATCH CARD — no "En
    /// route to pickup", no "Picked up" button, because the ride is not happening
    /// yet. On TestFlight r13 this scene's frame was `ownerDispatched`'s, a day
    /// early, over a car parked in the client's driveway.
    ///
    /// Deliberately SIMULATED. What it captures is the shipping `ownerDispatch`
    /// gate — `RideReservation.isLiveRide` — refusing a record, and that refusal is
    /// identical whichever service holds it; a live scene would add a clock and
    /// prove nothing extra. The record carries a real future `scheduledFor`, so the
    /// TIME half of dormancy is genuinely exercised rather than assumed.
    case ownerReservationDormant
    /// MYR-376 — Drives → Upcoming reading the SERVER, and the row's honest X.
    ///
    /// Live-path-only by construction: `OwnerDrivesState` reads reservations only
    /// when a source is composed, which in SIM never happens. It injects the
    /// PRODUCTION `LiveUpcomingReservations` over a scripted `DebugRideRequestEndpoint`
    /// — the same "real code path, injected wire" precedent `DebugShareEndpoint` and
    /// `DebugServiceWindowEndpoint` set — so the row in the capture came through the
    /// real fetch, the real `RideReservation.isUpcomingReservation` filter and the
    /// real contract fold.
    ///
    /// The endpoint carries THREE rows and the list renders ONE. The other two are
    /// the filter's evidence: an `arrived` reservation (the client's own — a ride
    /// with a passenger in it, still listed as upcoming before this issue) and a
    /// dispatched-but-still-`accepted` one. `ownerDrives` composes no source and
    /// keeps the fixture reservations, so it is byte-identical.
    case ownerReservationUpcoming
    /// MYR-378 — the OWNER'S RESERVATION DETAIL, which is the RIDER'S SHEET.
    ///
    /// `ownerReservationUpcoming` verbatim — same injected wire, same production
    /// `LiveUpcomingReservations`, same single rendered row — with the row's new tap
    /// already performed, because headless tooling cannot tap a list row (the same
    /// stand-in-for-a-tap precedent as `ownerFreshnessWaking` and this scene's own
    /// segment selection). The pair is therefore a clean before/after of exactly the
    /// detail: the list, then the list with its sheet up.
    ///
    /// Everything in frame belongs to `ScheduledRideSheet` — the map preview,
    /// pickup → drop-off, distance/drive, the vehicle card, Cancel and the disabled
    /// Reschedule with its caption — which is the whole point of the issue: the
    /// owner is not being shown a new component, they are being shown the rider's.
    /// The two role-specific differences are visible here and nowhere else: the
    /// vehicle card reads the CAR over "For {requester}" instead of the rider's
    /// "{Owner}'s {car} / {relationship}", and the destructive button reads
    /// "Cancel reservation".
    case ownerReservationDetail
    /// MYR-377 — the rider's Scheduled tab, alive.
    ///
    /// The client's own state: an accepted reservation for the next day that the
    /// tab reported as "0 scheduled · 0 confirmed / No scheduled rides". Injects
    /// wire rows behind the PRODUCTION `LiveRiderScheduledRides`, so the day/time
    /// grammar, the timezone resolution, the confirmed/pending split and the header
    /// counts are all the shipping mapping's. Two rows — one `accepted` (Confirmed)
    /// and one `requested` (Pending) — because the header counts both and the pair
    /// is what makes "N scheduled · M confirmed" readable as two different numbers.
    ///
    /// Live-path-only by construction: no store is composed in SIM, so
    /// `scheduledDetails` and its three siblings keep the fixtures and every
    /// existing capture is byte-identical.
    case riderScheduledLive
    /// MYR-377 — the rider AFTER the reservation dispatched: tracking + "Start ride".
    ///
    /// The deadlock this closes: the ride reached `arrived` (car at the kerb), the
    /// rider's map stayed on the idle in-service banner, and "Start ride" — the ONLY
    /// control that moves `arrived → enroute` — was never rendered, so the flow
    /// could not be completed at all. The seeded record is a reservation whose due
    /// moment has PASSED and whose dispatch latch is stamped, so what the capture
    /// shows is `RideReservation.isDormant` answering `false` and the shipping
    /// `reconciledPhase` letting the sheet through. `trackingArrived` is the
    /// instant-ride twin and is unchanged.
    case riderReservationLive
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
    /// MYR-294 — the two DRIVING heroes the prototype has no state for, both
    /// **live-path-only by construction**: every fixture trip carries the
    /// prototype's own destination literals, so `ownerHome` and every other
    /// simulated owner scene keeps the navigating hero and is byte-identical.
    /// Both inject `DebugDrivingNavigationFleet`, whose live-shaped
    /// `VehicleState` travels the production
    /// `VehicleContractMapping.navigation(from:)` — so the capture shows the
    /// shipping atomic-group classification, not a seeded enum.
    ///
    ///   • `ownerDrivingNoNav` — **the client's report**: *"When no navigation,
    ///     state just shows navigating — maybe remove that."* The nav group is
    ///     entirely null. Before this issue the same wire rendered the literal
    ///     word "Navigating" as a 28pt destination headline, "Arriving in 0 min",
    ///     "ETA <now>", a trip progress bar parked at its 5% clamp, and a Route
    ///     section whose destination leg read "· " and nothing else. The honest
    ///     hero is status / speed / battery / location, and the peek band is
    ///     `homePeekHeightDrivingNoNavigation` — the shorter hero gives its room
    ///     back instead of banking it as a gap above the nav (MYR-345's rule).
    ///   • `ownerDrivingResolvingDestination` — *"Taking a long time to populate
    ///     destination name even though route appeared."* RouteLine, ETA and
    ///     destination coordinates have landed; `DestinationName` has not. The
    ///     arrival pair and the trip bar are REAL and stay; the headline is the
    ///     speed and there is **no placeholder of any kind** — see
    ///     `DrivingHeroElement` for the client's rule. The first build of this
    ///     scene shimmered a skeleton in the destination slot and he rejected it
    ///     on sight: *"why are you skeleton loading when no route that looks so
    ///     weird and useless"*. Nothing is being fetched, so nothing may promise
    ///     to arrive.
    ///
    /// Pair either with `MRT_OWNER_DETENT=half` for the Route section, which is
    /// absent in BOTH — it is a two-ended statement and neither scene can name
    /// the far end.
    case ownerDrivingNoNav
    case ownerDrivingResolvingDestination
    /// MYR-345 — **the client's own screenshot** (AKXUQLSW…, Jul 29): a car IN
    /// SERVICE whose snapshot was read moments ago, so the peek hero carries BOTH
    /// live-only qualifier lines at once — the service-completion line under the
    /// In Service badge, and "Synced just now" at the foot. No scene reached that
    /// pair before: `ownerFreshnessStale` renders the stamp alone and
    /// `ownerServiceWindow` the completion line alone, and the peek band's
    /// per-line allowance only over-reserves when a line is actually drawn. It is
    /// the SAME fleet `ownerServiceWindow` injects, with the freshness stamp's live
    /// rendering forced on, so `ownerServiceWindow` itself stays byte-identical.
    ///
    /// It is also the DEAD-TAP repro: a car read "just now" is already current, so
    /// `VehicleFreshnessStamp.wakes` is false and the tap resolves to the
    /// acknowledgement — the branch that, before this issue, rendered NO copy at
    /// all and read as a stamp that does nothing.
    case ownerFreshnessInService
    /// MYR-345 — the same in-service car, STALE, whose §7.15 refresh the server
    /// legitimately REFUSES with the MYR-329 token (`502 command_failed`,
    /// `"vehicle command failed: vehicle_in_service"`). The tap therefore spends a
    /// real refresh, shows "Waking Model Y…", and settles on the NAMED reason
    /// rather than the generic "Couldn't reach the car" — the same lesson MYR-329
    /// taught on the command path, now on the refresh path. Capture at t≈1s
    /// (waking) and t≈4s (settled).
    case ownerFreshnessRefused
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
    /// MYR-342 → RE-POINTED BY MYR-369. The owner's RIDE-SHARING switch, in the
    /// one rendering that has no other capture route: the write IN FLIGHT.
    ///
    /// **THIS SCENE MOVED SURFACES, IT DID NOT CHANGE SUBJECT.** MYR-342 drew this
    /// switch as the last row of the owner sheet's "Status & location" card and
    /// these scenes booted there. MYR-369 moved the control to the top of the
    /// SHARE TAB and deleted the row — so for one release the scene still booted,
    /// still passed, and photographed a card that no longer contains its subject.
    /// A scene name that boots to the wrong surface is worse than a retired one:
    /// it reports success about a control it can no longer see.
    ///
    /// **TWO OF THE ORIGINAL THREE ARE RETIRED RATHER THAN MOVED.**
    /// `ownerRideShareOn` and `ownerRideSharePaused` captured the resting ON and
    /// PAUSED positions, and on the new surface `ownerShareControls` and
    /// `ownerShareVehiclePaused` already ARE that pair — the same two positions of
    /// the same switch, on the same card, as a deliberate one-toggle diff. Keeping
    /// four names for two frames is how a scene list stops being read.
    ///
    /// What survives is the arm nothing else covers. Against a real backend the
    /// pending state lasts milliseconds and cannot be raced by a screenshot, so
    /// the scene parks the write inside a stub that never answers
    /// (`DebugHangingRideShareEndpoint`) and performs the flip on appear through
    /// the SHIPPING `setVehicleRideShareEnabled` — the spinner is the real
    /// `VehicleRideShareRow.isBusy`, and the switch already reads its new position
    /// because the flip is OPTIMISTIC. The same park-in-one-branch precedent as
    /// MYR-326's `DebugLoadingFleet`, and the same standing-in-for-a-tap precedent
    /// as `ownerFreshnessWaking`.
    ///
    /// Live-path-only by construction, like every scene in the Share-tab family.
    case ownerRideSharePending
    /// MYR-358 → RE-POINTED BY MYR-369. The SAME switch on a car that is IN
    /// SERVICE: forced OFF, inert, and captioned "Off while in service — resumes
    /// automatically", now on the Share tab's relocated card.
    ///
    /// It needs its own scene because it is the only rendering whose position is
    /// DERIVED rather than read, and it is the REGRESSION GUARD for that
    /// derivation: the relocation dropped it, so for one release the card read the
    /// stored value straight through and an in-service car sat there advertising a
    /// ride it could not give. Nothing else on the new surface would have caught
    /// that — `ownerShareControls` seeds a car that is not in service, so it renders
    /// identically either way.
    ///
    /// The scene stores `rideShareEnabled: TRUE` deliberately — the capture is only
    /// proof of anything if the switch it shows OFF is a switch the server says is
    /// ON. A scene that seeded `false` would render an identical frame for the wrong
    /// reason and would still pass if the derivation were deleted again.
    ///
    /// Nothing is written on the transition: the stored `true` is untouched for the
    /// whole visit and renders again the moment the car leaves service, which is
    /// the property that keeps this state out of MYR-351's revert class entirely.
    /// The per-viewer Rides switches are in the same frame, dimmed, and captioned
    /// with the in-service FACT rather than with an owner choice nobody made.
    case ownerRideShareInService
    /// MYR-360 → RE-POINTED BY MYR-369. The PAUSE WARNING: the dialog an owner
    /// gets when they turn ride sharing off on a car that already carries an
    /// ACCEPTED FUTURE RESERVATION.
    ///
    /// Before MYR-360 the pause simply went through, the server HELD the
    /// reservation at due time, and it expired 30 minutes later — so the rider
    /// learned nobody was coming half an hour AFTER the pickup they had planned
    /// around. The dialog is the whole fix: it names what is booked and offers the
    /// decline the owner would otherwise have to go and find.
    ///
    /// **THESE TWO WERE THE SHARPEST STALE SCENES ON THE BRANCH.** MYR-369 moved
    /// the switch to the Share tab, and the warning was bound to the per-vehicle
    /// `VehicleCommandExecutor` seam the new call site does not have — so the
    /// feature stopped firing entirely while both scenes kept booting, kept
    /// flipping, and kept photographing an owner sheet with no switch on it. A
    /// capture that cannot fail is not evidence. The flow is re-homed onto
    /// `RideSharePauseTarget`, which both surfaces can supply, and these scenes
    /// now boot the tab that actually raises it.
    ///
    ///   • `ownerRideSharePauseWarning` — ONE reservation. The singular copy, the
    ///     singular confirm label ("Decline it and pause"), and the three-button
    ///     card in the shape everything else in this dialog family has.
    ///   • `ownerRideSharePauseWarningMulti` — FOUR reservations, which is also the
    ///     cap capture: the list names three and rolls the fourth up as a muted
    ///     "+1 more" row, and the confirm label pluralises to "Decline them and
    ///     pause". The SECOND reservation carries NO `requesterName` on the wire, so
    ///     the honest "A rider" fallback is in frame beside three named ones rather
    ///     than being asserted only in tests. The rolled-up fourth is still
    ///     declined by the confirm button — the display cap is a display cap and
    ///     nothing else.
    ///
    /// NOTHING in either capture is hand-set. Both build the Share tab against
    /// `DebugShareEndpoint` with the vehicle switch ON, hand the production
    /// `LiveUpcomingReservations` a scripted `DebugRideRequestEndpoint`, and
    /// perform the flip on appear through the SHIPPING
    /// `InvitesScreen.setVehicleRideShare`. So the wire is read by the real fetch,
    /// folded by the real `RideRequestContractMapping`, named by the real
    /// `IncomingRequestDisplay`, decided by the real `RideSharePause.decide` and
    /// written by the real `RideSharePauseDialog`.
    ///
    /// Both are LIVE-PATH-ONLY by construction and nothing else reads their
    /// overrides, so every simulated Share-tab capture is byte-identical.
    case ownerRideSharePauseWarning
    case ownerRideSharePauseWarningMulti
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
    /// MYR-361 — the SEARCH sheet's Now/Schedule segment DEFAULTED TO SCHEDULE,
    /// which is the client's own screenshot AKwpPQIV… inverted: *"Even though no
    /// car is available right now it's still allowing me to request a ride right
    /// now. Vs defaulting to scheduling."*
    ///
    /// Reuses `riderBusyVehicle`'s live-shaped `busyFleetMember` and its
    /// `MRT_BUSY_REASON=busy|inService|offline|paused` selector, so all four
    /// branches of the new default come out of ONE scene, built from real wire
    /// inputs through the REAL `LiveFleetMemberMapping`:
    ///
    ///   • `busy` / `inService` / `offline` → the segment opens on **Schedule**,
    ///     "Now" is dimmed and untappable, and the caption beneath it is
    ///     `RiderIdleAvailabilityBanner`'s own headline — the same sentence the
    ///     idle sheet showed one tap earlier.
    ///   • `paused` → **byte-identical to `search`'s segment**. The server refuses
    ///     reservations against a paused car too (§7.18), so there is no better
    ///     default to move to and the segment is deliberately left alone. That
    ///     pair — `paused` vs the other three, on one scene — is the whole rule.
    ///
    /// LIVE-PATH-ONLY BY CONSTRUCTION, like the MYR-352 banner it borrows its
    /// predicate from: every `FleetMember` fixture carries `unavailability == nil`
    /// and `SharedViewerState.liveFleetMembers` is empty in SIM, so `search`,
    /// `searchFiltered` and `searchSelected` stay byte-identical.
    case riderScheduleDefault
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

    // MARK: - Vehicle sharing (MYR-184) — ALL live-path-only
    //
    // Every state below is unreachable from a simulated capture BY CONSTRUCTION,
    // because the simulated sharing seams have no server: `SimulatedShareService`
    // mints no CODE (so no share sheet, no code caption, no tier line on a pending
    // row) and `SimulatedSharedVehicleCatalog` always has three grants on the
    // `rides` tier and a redeem that cannot fail (onboarding.jsx:421's forgiving
    // check). So the empty rider map, the sub-`rides` watch-only sheet, and every
    // redeem refusal have no other capture route at all.
    //
    // All five inject `DebugShareEndpoint` and run the PRODUCTION
    // `LiveShareService` / `LiveSharedVehicleCatalog` against it — the same
    // "real code path, injected wire" precedent as `DebugServiceWindowEndpoint`.
    // What the capture shows therefore came from the shipping grouping, the
    // shipping tier mapping, and the shipping gates, not from a hand-set flag.
    // Every existing scene is byte-identical: nothing consults these overrides
    // unless the scene is one of the five.

    /// MYR-184 — the owner Share tab on the SIMULATED path (`initialOwnerTab`
    /// "invites"), carrying the fixture roster: three accepted viewers with their
    /// presence dots and one pending invite. It is the MIXED arm of MYR-347's
    /// state matrix and the drift-gate anchor for this screen.
    ///
    /// MYR-347 CHANGED IT DELIBERATELY. It was the prototype's own render (an
    /// email field, two bare header+row stacks) and this comment used to say it
    /// must stay byte-identical forever; the client rejected that layout by name,
    /// and client outranks prototype. It is now the redesign's mixed-state
    /// capture and is byte-stable from this issue forward.
    case ownerShare

    /// MYR-347 — the state matrix the client actually photographed, on the
    /// SIMULATED path so the whole set is one cheap before/after.
    ///
    /// `ownerShareEmpty` is a brand-new account: nothing accepted, nothing
    /// pending, so the hero is the only thing on screen. It could not be captured
    /// at all before this issue — `SimulatedShareService` seeded
    /// `ShareFixtures.viewers`/`.pending` unconditionally, and the LIVE endpoint
    /// scenes all inject rows — which is exactly why the empty layout was never
    /// looked at.
    ///
    /// `ownerSharePendingOnly` is HIS state and the whole reason for the issue:
    /// zero accepted, one invite out. Before the redesign that rendered
    /// "VIEWERS · 0", a consolation sentence, then a "PENDING" header over one
    /// row — the "weird text in the middle saying viewers 0" verbatim.
    ///
    /// `ownerShareAcceptedOnly` is the other single-section arm, which proves the
    /// collapse works in both directions rather than only for the section that
    /// happened to be empty in his screenshot.
    case ownerShareEmpty
    case ownerSharePendingOnly
    case ownerShareAcceptedOnly

    /// MYR-369 — the PER-VIEWER SHARE CONTROLS, the state this issue exists for.
    ///
    /// `ownerShareControls` is the whole redesigned tab in one frame: the
    /// relocated vehicle ride-share card at the TOP (moved out of the owner
    /// sheet's "Status & location" card, same field and same §7.18 endpoint), and
    /// an accepted roster spanning every independent position the two per-viewer
    /// switches can now hold — rides ON, rides OFF, and SUSPENDED — plus a
    /// pending row that correctly has no switches at all.
    ///
    /// `ownerShareVehiclePaused` is the same page with the VEHICLE-level switch
    /// off. It exists because that is the only way to see the per-viewer Rides
    /// switches DISABLED: they are gated on the vehicle master toggle, and a row
    /// that greys out without saying why is the kind of silent state this app has
    /// been burned by. The pair is a clean one-toggle diff.
    ///
    /// Both are live-path-only by construction — `allowRides`/`suspended` exist
    /// only on a §7.5.2 owner listing — so every simulated Share-tab capture
    /// (`ownerShare`, the three MYR-347 matrix arms, both composer steps) is
    /// byte-identical.
    case ownerShareControls
    case ownerShareVehiclePaused

    /// MYR-347 — the two composer steps, which headless tooling cannot reach:
    /// step one is behind a tap on the hero CTA / "Invite someone" row, and step
    /// two additionally needs six characters typed into a field. Both seed the
    /// TAP (`initialSendStep`), not the result, so what the capture shows is the
    /// shipping composer with the shipping validation in front of it.
    ///
    /// `ownerShareComposer` is the recipient step WITH the keyboard up — the
    /// state MYR-344 was reported in, now structurally short enough to hold it.
    /// `ownerShareComposerAccess` is the configuration step, i.e. the sheet
    /// MYR-344 fixed, reached with a sample recipient already entered.
    case ownerShareComposer
    case ownerShareComposerAccess
    /// MYR-184 — the owner Share tab on the LIVE path (`initialOwnerTab`
    /// "invites"). The whole point of the pair with the simulated `ownerShare`:
    ///
    ///   • the pending row's caption names the CODE ("Code RBO246 · sent 2d ago")
    ///     where the fixture row names an email — §7.5 has no email anywhere;
    ///   • that row carries the TIER the owner chose ("Live + history"), which the
    ///     prototype's `doSend` discarded outright;
    ///   • the accepted viewer's presence dot is OFF, because v1 has NO presence
    ///     signal on the wire and the row must not claim someone is watching;
    ///   • ONE pending row stands for a MULTI-VEHICLE invite (two server rows,
    ///     one code) — the §7.5.1 regrouping, running for real.
    case ownerShareLive

    /// MYR-340 → MYR-359 → MYR-368 — the SYSTEM SHARE SHEET carrying what the
    /// client actually receives, which is the only artefact any of those issues
    /// changes. As of MYR-359 it is ONE URL handed over as a `URL` activity item,
    /// because iMessage builds the branded card only for a message that is nothing
    /// but a link. The sheet's preview therefore shows a LINK row, not a truncated
    /// paragraph; that difference IS the capture.
    ///
    /// **MYR-368 changes WHOSE URL it is.** The link is now minted and SIGNED by
    /// the server (`ShareInvite.shareUrl`, contracts 0.22.0) —
    /// `/join/{CODE}?k={kid}.{exp}.{sig}&from={Owner}&to={Recipient}`, with both
    /// names inside the Ed25519 signature — and the client forwards it verbatim.
    /// So `DebugShareEndpoint` mints one (`DebugSignedInviteLink`, the contract's
    /// shape with a stand-in signature) and the capture exercises the PRIMARY
    /// path. Without that, the scene would silently photograph the pre-0.22.0
    /// fallback and call it the new payload.
    ///
    /// It is unreachable from every other capture route: the sheet opens
    /// only after a Resend → confirm → Resend tap sequence (or a full compose +
    /// Send), and headless tooling can neither tap nor type. So the scene runs the
    /// PRODUCTION `LiveShareService.resend` against `ownerShareLive`'s own
    /// `DebugShareEndpoint` on appear — the same real-code-path/injected-wire
    /// precedent as `ownerServiceWindowSaved`, and the same stand-in-for-a-tap
    /// precedent as `autoSubmitsInviteCode`. The code in the capture is therefore
    /// genuinely minted by the shipping resend path, not hand-set, and the URL is
    /// resolved by the shipping `ShareInviteMessage`.
    ///
    /// This scene is the NAMED case — the link carries `&from=Thomas`, signed by
    /// the stub server off its `ownerDisplayName`. `namesShareMessageOwner` still
    /// supplies the owner profile, which now feeds only the fallback.
    case ownerShareMessage

    /// MYR-340 → MYR-359 → MYR-368 — the SAME share sheet for an account carrying
    /// NO name. Not a defensive branch: Apple returns a human name only on the
    /// FIRST authorization, and a row created before native sign-in may carry none
    /// at all, so a real fraction of owners hit this. The link then carries NO
    /// `from` parameter at all — never an empty one — and the landing page falls
    /// back to its generic heading, which is where the two-grammar rule lives now
    /// that the app sends no prose. The pair is a clean before/after of exactly
    /// that one query parameter.
    ///
    /// MYR-368 moved WHERE the omission is decided, without changing what the
    /// capture shows: the name is signed into the link server-side, so this scene
    /// is now the arm where `DebugShareEndpoint.ownerDisplayName` is `nil` and the
    /// SERVER omitted the parameter. `to=Mira` is still present on both, which is
    /// what keeps the pair a one-parameter diff rather than a two-parameter one.
    case ownerShareMessageNoName

    /// MYR-184 (MYR-228 fix (c)) — the rider Live Map with ZERO shared vehicles.
    /// A state that could not exist before this issue: `SharedViewerState.vehicle`
    /// defaulted to `VehicleFixtures.vehicles[0]` with no live gate, so a rider who
    /// had redeemed nothing watched a map captioned "Cybercab", a car on nobody's
    /// account, ticking fixture telemetry. The honest render has no map at all.
    case riderSharedEmpty

    /// MYR-184 (§7.5.0) — the rider idle sheet for a viewer BELOW the `rides`
    /// tier. The gold "Where to?" search bar is replaced by a muted "You can watch
    /// {car}" line, because the server will 403 a ride create from this tier and
    /// the client must not offer what will fail. Injects ONE `role: viewer` row on
    /// `live` and lets the shipping `SharedViewerState.canRequestRides` decide.
    case riderWatchOnly

    /// MYR-184 (§7.5.5) — the invite-code screen refusing on the RATE LIMIT.
    /// Distinct from the shake, deliberately: nothing is wrong with the code, and
    /// clearing + shaking would say "wrong code" and send the rider off to ask for
    /// a new one. The entry stays, and a quiet line says to wait. Auto-submits the
    /// sample code on appear (headless tooling cannot type six characters).
    case riderInviteRateLimited

    /// MYR-184 (MYR-228 fix (b)) — the invite success screen built from a REAL
    /// `RedeemShareInviteResponse`. It used to hardcode `InviteHostFixture`:
    /// "Alex's Model Y · Roommate · 2025 Tesla Model Y", a person and a car that
    /// exist nowhere. This one is the server's `ownerFirstName` + the granted
    /// vehicle, on a MULTI-VEHICLE invite so the "+1 more vehicle" line shows, and
    /// with the capability line reflecting the actual tier rather than promising
    /// rides unconditionally. Auto-submits like the scene above.
    case riderInviteJoined

    /// MYR-344 — the invite-code screen at REST, in entry, with nothing
    /// submitted: the state the two scenes above pass through in one frame on
    /// their way to a verdict, and the ONE the client photographed. It exists for
    /// the PASTE affordance, which lives only in `.entry` — the two scenes above
    /// leave that phase immediately, so neither can hold it still.
    ///
    /// It takes NO pasteboard seeding: the affordance is unconditional in `.entry`
    /// (see `InviteCodeFlow.pasteAffordance` for why a pasteboard-gated one cannot
    /// be built honestly), so this capture is deterministic regardless of what the
    /// capturing machine has on its clipboard.
    case riderInviteEntry

    /// MYR-343 — the client's own account: an OWNER who switched to rider mode.
    /// ZERO `role: viewer` rows and ONE `role: owner` row, which is exactly the
    /// shape that used to resolve to `riderSharedEmpty`'s invite-code prompt. The
    /// rider Live Map renders on the owner's OWN car, un-tier-gated, with the gold
    /// "Where to?" CTA up — the self-ride flow MYR-325 verified live.
    ///
    /// It is the AFTER half of a pair with `riderSharedEmpty`, which keeps the
    /// same catalog machinery and zero rows of BOTH roles and must stay
    /// byte-identical: the only difference between the two scenes is one owned row
    /// on the injected `GET /api/vehicles`, which is the whole issue.
    case riderOwnerSelfRide

    /// MYR-343 — the rider Live Map while the vehicle set is still RESOLVING: the
    /// `GET /api/vehicles` that decides between "ride your car", "ride the car
    /// shared with you" and "you have nothing" has not answered yet.
    ///
    /// This is the client's *"I briefly saw the rider home page"* frame, which
    /// before this issue was the rider home rendered over an unresolved set. It is
    /// now a skeleton shaped like the idle greeting sheet. The scene parks the
    /// list in flight and never resolves it (the same `DebugLoadingFleet` device),
    /// because on a healthy account the real state lasts milliseconds and has no
    /// other capture route. Capture it twice — once normally, once with Reduce
    /// Motion — to prove `MRTShimmerBand`'s fallback.
    case riderVehiclesResolving

    /// MYR-354 — owner Settings at the TOP of its scroll.
    ///
    /// `ownerSettings` boots scrolled to its own bottom anchor (MYR-224's
    /// "Switch to Rider" row is below the fold and headless tooling cannot
    /// scroll), which means the page's whole upper half — profile, Tesla Account,
    /// the head of "Shared with" — has never had a full-frame capture route at
    /// all. This issue changes exactly that half, so it needs one. Same scene,
    /// same data, one anchor fewer: `ownerSettings` keeps its bottom anchor and
    /// its role as the drift-gate pair's other end.
    case ownerSettingsTop

    /// MYR-354 — rider Settings for an account that OWNS a Tesla and has
    /// redeemed NOTHING: the client's own account, on the tab where he asked
    /// *"I own a vehicle so would it appear here or no?"*.
    ///
    /// The same one-owned-row / zero-viewer-rows `GET /api/vehicles` shape
    /// `riderOwnerSelfRide` injects, so the two scenes are the one account seen
    /// from its two tabs — and the pair is the proof that the map's "Where to?"
    /// and this section now agree about whether a car exists.
    ///
    /// Live-path-only by construction: `SimulatedSharedVehicleCatalog
    /// .ownedVehicles` is empty and its `grants` are the prototype's three
    /// personas, so `riderSettings` itself is a pure-viewer account and keeps
    /// the "Shared with me" label verbatim.
    case riderSettingsOwned

    /// MYR-354 — rider Settings for an account holding BOTH: one owned car and
    /// two redeemed shares. The state that pins the ORDER (owned first, matching
    /// `RiderVehicleSet`'s own adoption rule, because the ride is created against
    /// the owned car) and the label switch to "Vehicles" over a card whose other
    /// rows genuinely are shares.
    case riderSettingsMixed

    /// MYR-354 — rider Settings for an account with NOTHING: no owned car, no
    /// share. The ONE state where "No vehicles shared with you yet" is true, and
    /// the BEFORE half of the pair with `riderSettingsOwned` — before this issue
    /// both accounts saw this row.
    case riderSettingsEmpty

    /// MYR-343 — the rider Live Map when `GET /api/vehicles` FAILED and nothing
    /// about the account is known. Deliberately not the invite-code prompt ("no
    /// vehicles shared with you yet" is a claim one timed-out fetch cannot
    /// support) and deliberately not a skeleton (MYR-326: loading ≠ unavailable —
    /// nothing is in flight behind this screen). The honest line, and the same
    /// low-friction recovery the owner's cold-read timeout uses: a resume re-asks.
    case riderVehiclesUnreachable

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

    /// MYR-346 — simulate an INCOMING universal link, orthogonal to the scene.
    ///
    /// `MRT_JOIN_LINK` (or `-MRT_JOIN_LINK <value>`) takes either a full URL
    /// (`https://myrobotaxi.app/join/RBO246`) or a bare code (`RBO246`, composed
    /// into the same URL) and feeds it to `InviteLinkBridge` from `RootView.init`
    /// — i.e. BEFORE the view appears, which is exactly the cold-launch window
    /// the mailbox exists for, so the hook exercises the held-then-drained path
    /// rather than a shortcut around it.
    ///
    /// This exists because the real thing cannot be run yet: a universal link
    /// only reaches the app once `https://myrobotaxi.app/.well-known/apple-app-
    /// site-association` is DEPLOYED and iOS has fetched it for an installed
    /// build. Until then `xcrun simctl openurl` opens Safari, not the app. The
    /// routing decisions themselves are pinned by `InviteLinkRoutingTests`; this
    /// hook is for driving the real screens.
    ///
    ///     MRT_SCENE=ownerHome MRT_JOIN_LINK=RBO246          # signed-in, owner
    ///     MRT_JOIN_LINK=https://myrobotaxi.app/join/RBO246  # cold, signed-out
    ///
    /// Unset — which it is for every scene and every capture — nothing reads it
    /// and no scene changes by a pixel.
    static var incomingJoinLink: URL? {
        func parse(_ raw: String?) -> URL? {
            guard let raw, !raw.isEmpty else { return nil }
            if raw.contains("://") { return URL(string: raw) }
            guard let code = InviteLink.sanitize(raw) else { return nil }
            return URL(string: InviteLink.url(code: code))
        }
        if let value = parse(ProcessInfo.processInfo.environment["MRT_JOIN_LINK"]) { return value }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MRT_JOIN_LINK"), i + 1 < args.count { return parse(args[i + 1]) }
        return nil
    }

    /// Drift-gate flag for the `ownerHome` scene (MYR-236 r5.3): when
    /// `MRT_OWNER_DETENT=half` is set (env or `-MRT_OWNER_DETENT half` arg), the
    /// owner sheet boots resting at the HALF detent so the at-rest-half full-
    /// frame can be captured without a synthesized drag.
    ///
    /// MYR-332 adds `MRT_OWNER_DETENT=tall` for the new third detent, on the same
    /// spelling — headless tooling can no more drag to tall than it could to
    /// half. Unset, every scene boots at PEEK exactly as before. DEBUG-only.
    static var initialOwnerDetent: MRTSheetDetent? {
        func parse(_ raw: String?) -> MRTSheetDetent? {
            switch raw {
            case "half": return .half
            case "tall": return .tall
            default: return nil
            }
        }
        if let value = parse(ProcessInfo.processInfo.environment["MRT_OWNER_DETENT"]) { return value }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MRT_OWNER_DETENT"), i + 1 < args.count { return parse(args[i + 1]) }
        return nil
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
        // MYR-184 — the invite-code screen is its own top-level `AppScreen`, not a
        // rider tab, so it needs an explicit arm.
        case .riderInviteRateLimited, .riderInviteJoined, .riderInviteEntry: return .inviteCode
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
        // MYR-354 — the three vehicle-section scenes live on the same tab;
        // MYR-355 — so do the two rider deletion scenes.
        if current == .riderSettings
            || current == .riderSettingsOwned
            || current == .riderSettingsMixed
            || current == .riderSettingsEmpty
            || current == .riderDeleteAccount
            // MYR-366 — the rider's offboarding ending is the same tab.
            || current == .riderOffboardingDone { return "sharedSettings" }
        return current.isScheduled ? "rideHistory" : "shared"
    }

    static var initialOwnerTab: String {
        switch current {
        // MYR-376 — the live Upcoming read is the Drives tab.
        case .ownerDrives, .ownerDrivesLoading, .ownerReservationUpcoming,
             .ownerReservationDetail: return "drives"
        // MYR-354 adds `ownerSettingsTop`; MYR-347 adds the five Share scenes.
        case .ownerSettings, .ownerSettingsTop, .ownerSettingsLoading: return "settings"
        // MYR-355 / MYR-366 — the owner-shell deletion + offboarding scenes are
        // the Settings tab: that is where the flow is entered from.
        case .ownerDeleteAccount, .ownerOffboarding, .offboardingFailed, .ownerOffboardingDone:
            return "settings"
        case .ownerShare, .ownerShareLive, .ownerShareMessage, .ownerShareMessageNoName,
             .ownerShareEmpty, .ownerSharePendingOnly, .ownerShareAcceptedOnly,
             .ownerShareComposer, .ownerShareComposerAccess,
             // MYR-369 — the per-viewer control scenes are the Share tab too.
             .ownerShareControls, .ownerShareVehiclePaused,
             // MYR-369 — AND SO ARE THE RIDE-SHARE SCENES NOW. They used to fall
             // through to `"home"` and photograph the owner sheet's Status &
             // location card, which is where that switch lived until this issue
             // moved it. This line is the whole of "a scene name must not boot to
             // the wrong surface": without it they still run, still pass, and show
             // a card their subject has left.
             .ownerRideSharePending, .ownerRideShareInService,
             .ownerRideSharePauseWarning, .ownerRideSharePauseWarningMulti:
            return "invites"
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
            // MYR-354 — the four new Settings capture scenes carry the same
            // DEBUG identity their siblings do, so the profile card and the
            // mode-switch row are in frame for the grammar comparison.
            || self == .ownerSettingsTop
            || self == .riderSettingsOwned || self == .riderSettingsMixed
            || self == .riderSettingsEmpty
            // MYR-355 — the deletion scenes are the same screens with a dialog (or,
            // since MYR-366, a full-screen cover) up, so they carry the same
            // identity: the Settings page underneath must show what the drift-gate
            // pair shows.
            || accountDeletionStage != nil
    }

    /// MYR-355 → MYR-366 — how far the SHIPPING `AccountDeletionFlow` should be
    /// driven on boot, or `nil` for every other scene (which therefore never
    /// constructs a dialog and stays byte-identical).
    ///
    /// It is a stand-in for the TAPS and nothing else — see
    /// `AccountDeletionFlow.debugDrive`. **Which offboarding state a scene lands
    /// on is decided by the WIRE it injects, never by a flag**: the four
    /// offboarding scenes all run `.offboarding` and differ only in what
    /// `accountDeletionEndpoint` hands them, so what a capture shows came out of
    /// the shipping state machine reconciling a real answer (or a real absence of
    /// one) rather than a hand-set phase.
    var accountDeletionStage: AccountDeletionFlow.DebugStage? {
        switch self {
        case .ownerDeleteAccount, .riderDeleteAccount: return .dialog
        case .ownerOffboarding, .offboardingFailed,
             .ownerOffboardingDone, .riderOffboardingDone: return .offboarding
        default: return nil
        }
    }

    /// MYR-355 → MYR-366 — the scripted account-deletion wire.
    ///
    /// `nil` for the two DIALOG scenes, which never reach the endpoint at all, and
    /// `nil` for the two ENDING scenes, where the simulator's own absent endpoint
    /// is the honest success (there is no server account to delete in SIM, so the
    /// `204` case is exactly what the composition already produces — and it costs
    /// nothing, since Done is the only thing that would sign anyone out and no
    /// capture taps it).
    var accountDeletionEndpoint: (any AccountDeletionEndpoint)? {
        switch self {
        // Never answers: the ONLY way to hold the mid-flight frames still.
        case .ownerOffboarding:
            return DebugAccountDeletionEndpoint(hangs: true)
        // A real throw through the shipping catch, held long enough that the
        // narration is genuinely part-way down the sequence when it lands.
        case .offboardingFailed:
            return DebugAccountDeletionEndpoint(
                failure: DebugAccountDeletionEndpoint.internalError,
                delay: 1.2
            )
        default:
            return nil
        }
    }

    /// MYR-340 — whether the SHARE MESSAGE should be composed with a real owner
    /// first name. The opening line is live-only by construction: SIM mints no
    /// code, so it never opens a share sheet at all, and the simulator carries no
    /// authenticated account to take a name from. Same stand-in-for-a-live-session
    /// precedent as `showsLiveSettings`. Scoped to `ownerShareLive`, so no other
    /// scene gains an identity.
    var namesShareMessageOwner: Bool {
        self == .ownerShareLive || self == .ownerShareMessage
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
            // MYR-345 — the client's two-qualifier-line variant + the refusal
            // settle. Both are the freshness stamp on an in-service car, so they
            // need the same live rendering the two MYR-315 scenes force.
            || self == .ownerFreshnessInService || self == .ownerFreshnessRefused
    }

    /// MYR-316 — whether `HomeScreen` should boot with the "Expected back" entry
    /// sheet already presented. The sheet opens from a row inside the half-detent
    /// controls scroll, which headless capture tooling cannot tap; seeding the
    /// presentation is the same stand-in-for-a-tap move `initialRefreshPhase`
    /// makes. Scoped to the one scene, so no other capture gains an overlay.
    var opensServiceWindowEditor: Bool { self == .ownerServiceWindowEditor }

    /// MYR-360, re-pointed by MYR-369 — whether `InvitesScreen` should perform the
    /// ride-share PAUSE FLIP on boot, through the shipping `setVehicleRideShare`.
    ///
    /// Headless capture tooling cannot tap a switch, and these two states are
    /// reachable only THROUGH one. Standing in for that single tap is the same move
    /// `ownerFreshnessWaking` and `ownerServiceWindowEditor` make — and it is a
    /// stand-in for the TAP only: everything downstream of it (the reservation read,
    /// the decision, the copy, the dialog, the write) is the shipping path running
    /// for real.
    ///
    /// It reads `false` for the flip DIRECTION as well as the trigger: only the OFF
    /// direction warns, so a scene that flipped ON would capture nothing at all.
    ///
    /// `ownerRideSharePending` uses it too — it flips through the same entry point,
    /// and its stub simply never answers, so the write parks in flight instead of
    /// reaching a decision. Scoped to those three, so no other capture writes
    /// anything on boot.
    var flipsRideShareOnBoot: Bool {
        self == .ownerRideSharePauseWarning || self == .ownerRideSharePauseWarningMulti
            || self == .ownerRideSharePending
    }

    /// MYR-360 — the scripted reservation seam for the two pause-warning scenes,
    /// behind the PRODUCTION `LiveUpcomingReservations`.
    ///
    /// The scene supplies WIRE ROWS and nothing else: the fetch, the paging, the
    /// contract fold, the name resolution and the copy are all the shipping code's,
    /// so what the capture shows is what the app would build from a real server's
    /// answer. `nil` for every other scene, which is what leaves every other
    /// ride-share capture byte-identical.
    ///
    /// MYR-369 — the rows are stamped with the SHARE TAB's car, since that is the
    /// surface these scenes boot now and the id the flow asks about.
    @MainActor
    var upcomingReservationSource: (any UpcomingReservationSource)? {
        let vehicleID = Self.shareControlsVehicleID
        switch self {
        case .ownerRideSharePauseWarning:
            return LiveUpcomingReservations(api: DebugRideRequestEndpoint(reservations: [
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000031",
                    vehicleID: vehicleID,
                    requesterName: "Alex",
                    scheduledFor: DebugRideRequestEndpoint.sampleReservationDate()
                )
            ]))
        case .ownerRideSharePauseWarningMulti:
            // Soonest first, exactly as the server orders them. The SECOND row
            // carries no `requesterName`, so the honest "A rider" fallback renders
            // beside three named riders — a nameless reservation is a real wire
            // shape (§7.8 omits the key when the identity lookup resolved nothing)
            // and the client must never fill it in. Deliberately NOT the internal
            // role term "Shared viewer", which is the incoming card's answer to a
            // different question.
            return LiveUpcomingReservations(api: DebugRideRequestEndpoint(reservations: [
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000031",
                    vehicleID: vehicleID,
                    requesterName: "Alex",
                    scheduledFor: DebugRideRequestEndpoint.sampleReservationDate()
                ),
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000032",
                    vehicleID: vehicleID,
                    requesterName: nil,
                    scheduledFor: DebugRideRequestEndpoint.sampleReservationDate(
                        daysAhead: 1, hour: 9, minute: 15
                    )
                ),
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000033",
                    vehicleID: vehicleID,
                    requesterName: "Priya",
                    scheduledFor: DebugRideRequestEndpoint.sampleReservationDate(
                        daysAhead: 4, hour: 19, minute: 0
                    )
                ),
                // The FOURTH is what puts the rollup row in frame: the list caps at
                // three named rows, so this one is only ever seen as "+1 more" — and
                // it is still declined by "Decline them and pause", which is the
                // property the capture is really evidence of.
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000034",
                    vehicleID: vehicleID,
                    requesterName: "Sam",
                    scheduledFor: DebugRideRequestEndpoint.sampleReservationDate(
                        daysAhead: 6, hour: 8, minute: 45
                    )
                )
            ]))
        case .ownerReservationUpcoming, .ownerReservationDetail:
            // MYR-376 — THREE rows in, ONE row out. The two that are filtered away
            // are the evidence, not padding: the `arrived` one is the client's own
            // screenshot (a ride with a passenger in it, still listed as "upcoming"
            // before this issue), and the dispatched-`accepted` one is the same
            // defect one status earlier. Everything about the exclusion is the
            // shipping `RideReservation.isUpcomingReservation` running for real.
            //
            // Stamped with the SIM fleet's first car, because this scene boots the
            // owner shell on the fixture fleet and `DrivesScreen` asks for the
            // SELECTED vehicle's reservations.
            let drivesVehicleID = VehicleFixtures.vehicles[0].id
            return LiveUpcomingReservations(api: DebugRideRequestEndpoint(reservations: [
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000041",
                    vehicleID: drivesVehicleID,
                    requesterName: Self.sampleProfile.firstName,
                    scheduledFor: Self.sampleDormantReservationDate
                ),
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000042",
                    vehicleID: drivesVehicleID,
                    requesterName: "Mira",
                    scheduledFor: Date().addingTimeInterval(-30 * 60),
                    status: .arrived,
                    dispatchedAt: Date().addingTimeInterval(-30 * 60),
                    dispatchStatus: .sent
                ),
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000043",
                    vehicleID: drivesVehicleID,
                    requesterName: "Jonas",
                    scheduledFor: Date().addingTimeInterval(-5 * 60),
                    dispatchedAt: Date().addingTimeInterval(-5 * 60),
                    dispatchStatus: .sent
                ),
            ]))
        default:
            return nil
        }
    }

    /// MYR-376 — boot `DrivesScreen` on its UPCOMING segment. Exactly one scene, so
    /// `ownerDrives` and `ownerDrivesLoading` keep the History default and stay
    /// byte-identical. Headless tooling cannot tap a segmented control, so without
    /// this the reservation read has no capture route at all — the same
    /// stand-in-for-a-tap precedent as `ownerFreshnessWaking`.
    var opensUpcomingDrivesTab: Bool { self == .ownerReservationUpcoming || self == .ownerReservationDetail }

    /// MYR-378 — open the FIRST upcoming reservation's detail sheet on appear. A
    /// stand-in for the row TAP only: the sheet, its role and everything it renders
    /// are the shipping ones.
    var opensFirstReservationDetail: Bool { self == .ownerReservationDetail }

    /// MYR-377 — the rider twin of the above, for `RideHistoryScreen`'s Scheduled
    /// segment. Exactly one scene, so the four MYR-200 `scheduled*` scenes (which
    /// open the SHEET over whichever tab is behind it) are untouched.
    var opensScheduledTab: Bool { self == .riderScheduledLive }

    /// MYR-377 — the scripted rider Scheduled-tab seam, behind the PRODUCTION
    /// `LiveRiderScheduledRides`.
    ///
    /// Same "real code path, injected wire" precedent as every other endpoint stub
    /// in this file: the scene supplies wire rows and the shipping mapping does the
    /// day/time grammar, the timezone resolution, the dormancy filter and the
    /// confirmed/pending split. `nil` for every other scene, so `scheduledDetails`
    /// and its three siblings keep the fixtures and stay byte-identical.
    @MainActor
    var scheduledRideSource: (any RiderScheduledRideSource)? {
        guard self == .riderScheduledLive else { return nil }
        let vehicleID = VehicleFixtures.vehicles[0].id
        return LiveRiderScheduledRides(
            api: DebugRideRequestEndpoint(rides: [
                // ACCEPTED — the client's own reservation, and the one the tab
                // reported as not existing. Renders "Confirmed".
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000051",
                    vehicleID: vehicleID,
                    requesterName: Self.sampleProfile.firstName,
                    scheduledFor: Self.sampleDormantReservationDate
                ),
                // REQUESTED — nobody has answered it. Renders "Pending", which is
                // what makes the header's two counts read as two numbers.
                DebugRideRequestEndpoint.reservation(
                    id: "clride0000000000000052",
                    vehicleID: vehicleID,
                    requesterName: Self.sampleProfile.firstName,
                    scheduledFor: DebugRideRequestEndpoint.sampleReservationDate(hour: 8, minute: 30),
                    status: .requested
                ),
            ]),
            // The car is named from the rider's own fleet, exactly as the live path
            // names it. A literal here would be the MYR-228 leak this scene exists
            // partly to prove the absence of.
            vehicleNames: { id in
                guard id == vehicleID else { return nil }
                return RiderScheduledRideVehicle(
                    name: VehicleFixtures.vehicles[0].name,
                    relationship: "Your Tesla"
                )
            }
        )
    }

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
            || self == .ownerSettingsTop
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
            || self == .ownerDrivingNoNav || self == .ownerDrivingResolvingDestination
            || self == .ownerFreshnessInService || self == .ownerFreshnessRefused
            || self == .ownerServiceWindow || self == .ownerServiceWindowEditor
            || self == .ownerServiceWindowManual || self == .ownerServiceWindowSaved
            || self == .ownerRideSharePending || self == .ownerRideShareInService
            || self == .ownerRideSharePauseWarning || self == .ownerRideSharePauseWarningMulti
            // MYR-376 — both reservation-lifecycle owner scenes.
            || self == .ownerReservationDormant || self == .ownerReservationUpcoming
            // MYR-378 — the detail sheet the Upcoming row now opens.
            || self == .ownerReservationDetail
            || self == .ownerCharging || self == .ownerChargeComplete
            || self == .ownerNoticeRejected || self == .ownerNoticeRejectedInService
            || self == .ownerVehicleEnriched
            || self == .ownerConnecting || self == .ownerConnectingCold
            || self == .ownerDrivesLoading || self == .ownerSettingsLoading
            || self == .ownerShare || self == .ownerShareLive
            || self == .ownerShareMessage || self == .ownerShareMessageNoName
            || self == .ownerShareEmpty || self == .ownerSharePendingOnly
            || self == .ownerShareAcceptedOnly
            || self == .ownerShareComposer || self == .ownerShareComposerAccess
            // MYR-369 — per-viewer share controls. This is the `isOwner` chain
            // the repo's own notes flag as the classic miss: without it the scene
            // boots the RIDER shell and the Share tab is unreachable.
            || self == .ownerShareControls || self == .ownerShareVehiclePaused
            // MYR-355 — the owner-shell deletion scenes. MYR-366 — `offboarding
            // Failed` is captured on the OWNER shell because the owner's sequence
            // is the longer one and therefore the harder stepper to stop honestly
            // part-way down.
            || self == .ownerDeleteAccount || self == .ownerOffboarding
            || self == .offboardingFailed || self == .ownerOffboardingDone
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
        // MYR-294 — a car DRIVING, with the navigation atomic group either
        // entirely absent or present-without-a-name. The production mapping does
        // the classifying (see `DebugDrivingNavigationFleet`).
        case .ownerDrivingNoNav:
            return DebugDrivingNavigationFleet(condition: .noNavigation)
        case .ownerDrivingResolvingDestination:
            return DebugDrivingNavigationFleet(condition: .resolvingDestination)
        // MYR-345 — the client's own condition: the SAME in-service fleet
        // `ownerServiceWindow` injects (so that scene stays byte-identical), read
        // moments ago, with the stamp's live rendering forced on. Both live-only
        // qualifier lines are therefore drawn at once — the pair the peek band's
        // per-line allowance is measured against.
        case .ownerFreshnessInService:
            return DebugVehicleDetailsFleet(
                status: .inService,
                serviceEstimatedEndAt: DebugScene.sampleServiceEnd()
            )
        // MYR-345 — the same car read HOURS ago, so the tap spends a real §7.15
        // call, and a server that refuses it by NAME (§7.9's `command_failed`
        // carrying MYR-329's `vehicle_in_service` token).
        case .ownerFreshnessRefused:
            return DebugVehicleDetailsFleet(
                status: .inService,
                serviceEstimatedEndAt: DebugScene.sampleServiceEnd(),
                lastReadAt: Date().addingTimeInterval(-7 * 3600),
                refreshFailure: .http(
                    status: 502,
                    code: ErrorPayload.Code(rawValue: "command_failed"),
                    message: "vehicle command failed: vehicle_in_service",
                    subCode: nil
                )
            )
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
        // MYR-369 — THE RIDE-SHARE SCENES INJECT NO FLEET AT ALL any more. They
        // are Share-tab scenes now, and that tab reads its cars from the
        // `ShareService` seam (`shareServiceOverride`), never from this owner-sheet
        // fleet. Leaving their arms here would seed a car nothing on the captured
        // surface reads — the quiet kind of wrong that keeps a scene passing.
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
        // MYR-369 — the ride-share scenes have NO owner-sheet anchor any more.
        // They do not boot the owner sheet at all; the Share tab is a plain
        // scrolling page and the relocated card LEADS it, so the subject is in
        // frame with no anchor at all. `MRT_OWNER_DETENT` is likewise meaningless
        // for them now.
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
        // MYR-377 — the live Scheduled tab is the same tab.
        case .riderScheduledLive: return true
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

    /// MYR-356 — boot the search sheet with the keyboard DOWN. True for exactly one
    /// scene, whose subject (the pre-typing Recent section) is otherwise behind it.
    /// See `RideRequestSearchContent.scheduleSearchFocus`.
    var suppressesSearchAutoFocus: Bool { self == .riderRecentDestinations }

    /// MYR-356 — the recents this scene boots with. EMPTY for every scene but
    /// `riderRecentDestinations`, which is what keeps every existing capture
    /// byte-identical (see `RootView.recentDestinationsStore()`).
    ///
    /// SIX rows for a cap of five, oldest last, so the capture proves both the cap
    /// and the ordering. Real-shaped: no measured distance (a live autocomplete row
    /// carries none), and a `live-unresolved|` id on one of them — the shape MYR-237
    /// stores when the rider chose a suggestion before its coordinate resolved,
    /// which selecting the row re-resolves exactly as a fresh search row would.
    /// MYR-172 — whether this scene starts a real Live Activity on boot.
    ///
    /// Exactly one scene does. Everything else in the app is untouched, which is
    /// what keeps every other capture byte-identical — an Activity is a system-wide
    /// side effect, and starting one speculatively would leave a card on the lock
    /// screen of whatever the next capture happened to be.
    var startsSampleLiveActivity: Bool { self == .riderLiveActivity }

    /// Which frame `riderLiveActivity` should show, from `MRT_ACTIVITY_STATE`.
    ///
    /// Returns the content state AND its stale-date, because the stale arm is not a
    /// different content state at all — it is the SAME frame handed a stale-date
    /// that has already passed. ActivityKit offers no way to force staleness, so
    /// being genuinely stale is the only way to photograph `context.isStale`.
    @MainActor
    var sampleLiveActivityFrame: (state: RideActivityAttributes.ContentState, staleDate: Date?)? {
        guard startsSampleLiveActivity else { return nil }

        switch ProcessInfo.processInfo.environment["MRT_ACTIVITY_STATE"] ?? "enroute" {
        case "accepted":
            return (RideActivityDebugLauncher.sampleState(status: .accepted, etaMinutesFromNow: 6), nil)
        case "arrived":
            // A car that is HERE has nothing to count down to, so the frame carries
            // no ETA — the same omission a real server sends.
            return (RideActivityDebugLauncher.sampleState(status: .arrived, etaMinutesFromNow: nil), nil)
        case "completed":
            return (RideActivityDebugLauncher.sampleState(status: .completed, etaMinutesFromNow: nil), nil)
        case "stale":
            // A stale-date a few seconds in the FUTURE, which then passes.
            //
            // The obvious seeding — a stale-date in the PAST, so the frame is born
            // stale — DOES NOT WORK, and this was established by capture rather
            // than by reading: ActivityKit evidently ignores or clamps a stale-date
            // that has already elapsed at `request` time, and the Dynamic Island
            // kept rendering the confident gold countdown. There is no API to force
            // staleness, so the only way to photograph `context.isStale` is to be
            // genuinely stale, which means waiting for a real deadline to pass.
            //
            // CAPTURE AT t ≳ 15s after launch. Before that the card is correctly
            // NOT stale and the capture is of the ordinary enroute frame.
            return (
                RideActivityDebugLauncher.sampleState(status: .enroute, etaMinutesFromNow: 4),
                Date().addingTimeInterval(8)
            )
        default:
            return (RideActivityDebugLauncher.sampleState(status: .enroute, etaMinutesFromNow: 4), nil)
        }
    }

    var seededRecentDestinations: [RecentDestination] {
        guard self == .riderRecentDestinations else { return [] }
        let now = Date()
        let rows: [(String, String, String, Double, Double)] = [
            ("rec-ferry", "Ferry Building", "1 Ferry Building · Embarcadero", 37.7955, -122.3937),
            ("rec-sfo", "SFO · Terminal 2", "San Francisco International", 37.6213, -122.3790),
            ("live-unresolved|tartine", "Tartine Bakery", "600 Guerrero St · Mission", 37.7614, -122.4241),
            ("rec-crissy", "Crissy Field", "1199 East Beach", 37.8039, -122.4644),
            ("rec-sfmoma", "SFMOMA", "151 3rd St · SoMa", 37.7857, -122.4011),
            ("rec-pier39", "Pier 39", "Beach St · Wharf", 37.8087, -122.4098),
        ]
        return rows.enumerated().map { index, row in
            RecentDestination(
                id: row.0, label: row.1, subtitle: row.2,
                latitude: row.3, longitude: row.4,
                // Descending, so the array order IS the recency order the shipping
                // list rule produces.
                chosenAt: now.addingTimeInterval(-Double(index) * 3600)
            )
        }
    }

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
        switch self {
        case .pinDropBackRealPath: return DriveFixtures.financialDistrict
        // MYR-341 — the rider's own location, the endpoint the pickup ETA is
        // measured TO. Financial District, the same SF region the sim map uses.
        case .riderIdleETA, .riderIdleETABusy: return DriveFixtures.financialDistrict
        default: return nil
        }
    }

    /// MYR-341 — the watched vehicle's coordinate for the idle-ETA captures: the
    /// endpoint the pickup ETA is measured FROM. ~2.8 mi north-west of the rider
    /// (Marina-ish), so the shipping closed form lands on a plausible single-digit
    /// number well clear of the ≥1 min clamp.
    static let idleETAVehicleFix = CLLocationCoordinate2D(latitude: 37.8010, longitude: -122.4460)

    /// MYR-341 — an AVAILABLE live-shaped vehicle for the `riderIdleETA` capture,
    /// built through the REAL `LiveFleetMemberMapping.fleetMember(from:)` so the
    /// scene exercises the shipping availability predicate (and the shipping
    /// `etaMin: 0` sentinel the ETA seam then fills) rather than a hand-set flag.
    /// `riderIdleETABusy` reuses it with `hasActiveRide: true`, which is the only
    /// difference between the two captures.
    private static func idleETAFleetMember(busy: Bool) -> FleetMember {
        LiveFleetMemberMapping.fleetMember(from: VehicleSummary(
            vehicleId: "debug-idle-eta",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vinLast4: "2046",
            status: .parked,
            chargeLevel: 68,
            estimatedRange: 240,
            lastUpdated: "2026-07-26T12:00:00Z",
            role: .owner,
            hasActiveRide: busy
        ))
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
        // MYR-342 — a PARKED car, deliberately: the whole point of the pause is
        // that the vehicle itself is perfectly healthy and available and the OWNER
        // has withdrawn it. Driving the wire input this way means the capture
        // proves the precedence too — a parked, idle car with no active ride reads
        // as `paused` only if `rideShareEnabled: false` is doing the work.
        case .paused: status = .parked
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
            hasActiveRide: reason == .busy,
            // MYR-342 — the same "real wire input per state" discipline: the pause
            // comes from the CONTRACT FIELD, so a capture that renders the Paused
            // chip and the button-less CTA area proves the shipping predicate and
            // the shipping gate, not a hand-set flag. Absent (nil) for every other
            // reason, which is what keeps those three captures byte-identical.
            rideShareEnabled: reason == .paused ? false : nil
        ))
    }

    /// MYR-352 — a live-SHAPED MULTI-vehicle set for `riderNoRidesFleet`: two
    /// cars, both unavailable, for two DIFFERENT reasons. Built through the REAL
    /// `LiveFleetMemberMapping.fleetMember(from:)` from real wire inputs (a
    /// `status: .inService` row and a `status: .offline` row), so the capture
    /// proves the shipping predicate answered `unavailability` on every row before
    /// the banner generalized — the generic headline is only correct BECAUSE no row
    /// came back requestable.
    ///
    /// Two different reasons deliberately: a fleet out for one shared reason is the
    /// case where a specific headline would tempt, and this scene is the one that
    /// shows why the generic line is the only true sentence about the set.
    private static var noRidesFleetMembers: [FleetMember] {
        [
            LiveFleetMemberMapping.fleetMember(from: VehicleSummary(
                vehicleId: "debug-fleet-1",
                name: "Lunar",
                model: "Model Y",
                year: 2026,
                color: "Quicksilver",
                vinLast4: "2046",
                status: .inService,
                chargeLevel: 68,
                estimatedRange: 240,
                lastUpdated: "2026-07-26T12:00:00Z",
                role: .owner
            )),
            LiveFleetMemberMapping.fleetMember(from: VehicleSummary(
                vehicleId: "debug-fleet-2",
                name: "Comet",
                model: "Model 3",
                year: 2025,
                color: "Deep Blue Metallic",
                vinLast4: "7731",
                status: .offline,
                chargeLevel: 41,
                estimatedRange: 130,
                lastUpdated: "2026-07-26T09:00:00Z",
                role: .viewer
            ))
        ]
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
        case .ownerReservationDormant:
            // MYR-376 — accepted, scheduled for TOMORROW at noon, NOT dispatched.
            // Every input the gate reads is real: a future instant and two absent
            // dispatch fields. `ownerDispatch` therefore answers nil and the card
            // does not render — which is the whole capture.
            return record(
                status: .accepted,
                schedule: RideSchedule(day: "Tomorrow", time: "12:00 PM"),
                requesterName: Self.sampleProfile.firstName,
                scheduledFor: Self.sampleDormantReservationDate
            )
        case .riderReservationLive:
            // MYR-377 — the SAME reservation an hour after its moment, with the
            // sweeper's latch stamped. `isDormant` is false on both counts, so the
            // rider's tracking sheet and its "Start ride" CTA are reachable.
            return record(
                status: .arrived,
                progress: RideRequestTiming.autoAcceptInitialProgress,
                schedule: RideSchedule(day: "Today", time: "12:00 PM"),
                scheduledFor: Date().addingTimeInterval(-15 * 60),
                dispatchedAt: Date().addingTimeInterval(-15 * 60),
                dispatchStatus: .sent
            )
        default:
            return nil
        }
    }

    /// MYR-376 — tomorrow at noon, the client's own reservation shape, computed
    /// relative to `now` for the same reason `DebugScene.sampleServiceEnd` is: a
    /// literal drifts into the past and the scene would then photograph a PAST-DUE
    /// reservation, which is a different state entirely (and, under the
    /// time-bounded dormancy rule, the OPPOSITE one).
    static var sampleDormantReservationDate: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: tomorrow) ?? tomorrow
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
        requesterName: String? = nil,
        // MYR-376/377 — the three reservation facts. All three default to `nil`, so
        // every pre-existing scene seeds exactly the record it seeded before.
        scheduledFor: Date? = nil,
        dispatchedAt: Date? = nil,
        dispatchStatus: DispatchStatus? = nil
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
        rec.scheduledFor = scheduledFor
        rec.dispatchedAt = dispatchedAt
        rec.dispatchStatus = dispatchStatus
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
        case .riderIdleETA, .riderIdleETABusy:
            // MYR-341 — the idle sheet, plus the three live-shaped inputs the
            // placeholder's real ETA needs. Everything downstream (quantization,
            // the estimator, the gates, the copy) is the shipping code.
            viewer.debugResolvesLivePickupETA = true
            viewer.debugVehicleCoordinateOverride = DebugScene.idleETAVehicleFix
            viewer.debugFleetMemberOverride = DebugScene.idleETAFleetMember(busy: self == .riderIdleETABusy)
            viewer.refreshPickupETAAnchors()
            viewer.sheetPhase = .idle
        case .riderNoRides:
            // MYR-352 — the idle sheet plus ONE unavailable live-shaped vehicle,
            // reusing `riderBusyVehicle`'s own reason selector so all four headline
            // variants come out of this one scene. Nothing about the banner is
            // hand-set: the shipping `LiveFleetMemberMapping` answers
            // `unavailability` and the shipping `RiderIdleAvailabilityBanner`
            // composes the copy.
            viewer.debugFleetMemberOverride = DebugScene.busyFleetMember
            viewer.sheetPhase = .idle
        case .riderNoRidesFleet:
            // MYR-352 — the MULTI-vehicle set, the input that selects the generic
            // headline. The whole list travels the real mapping.
            viewer.debugFleetMembersOverride = DebugScene.noRidesFleetMembers
            viewer.sheetPhase = .idle
        case .riderLiveActivity:
            // MYR-172 — the app itself just sits on the ordinary idle sheet; the
            // subject of this capture is drawn by the widget EXTENSION, started
            // separately in `startsSampleLiveActivity`.
            viewer.sheetPhase = .idle
        case .riderReservationLive:
            // MYR-377 — the reservation has dispatched, so the rider is on the
            // ORDINARY tracking sheet. Same draft seeding as `trackingArrived`,
            // because after dispatch a reservation is a live ride with no special
            // case anywhere downstream — which is the point.
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .tracking
        case .declined:
            viewer.sheetPhase = .search
            viewer.showDeclinedNotice = true
        case .search, .searchFiltered:
            viewer.sheetPhase = .search
        case .riderRecentDestinations:
            // MYR-356 — `search` verbatim. The ONLY difference is the store
            // `RootView` handed the state at init (`seededRecentDestinations`).
            viewer.sheetPhase = .search
        case .riderScheduleDefault:
            // MYR-361 — `search` verbatim, plus ONE unavailable live-shaped
            // vehicle. Nothing about the segment is hand-set: the shipping
            // `LiveFleetMemberMapping` answers `unavailability`, the shipping
            // `RideSchedulingAvailability` decides the default, and the shipping
            // `RiderIdleAvailabilityBanner` composes the caption.
            viewer.debugFleetMemberOverride = DebugScene.busyFleetMember
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
        case .modeChooser, .ownerSettings, .ownerSettingsTop, .riderSettings,
             .riderSettingsOwned, .riderSettingsMixed, .riderSettingsEmpty,
             // MYR-355 — settings scenes: nothing about the rider sheet is seeded.
             .ownerDeleteAccount, .riderDeleteAccount,
             // MYR-366 — the offboarding scenes seed nothing about the rider sheet
             // either; they are the same two settings screens with a cover up.
             .ownerOffboarding, .offboardingFailed,
             .ownerOffboardingDone, .riderOffboardingDone,
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
             // MYR-376 — the two owner reservation scenes seed nothing about the
             // rider sheet; the dormant one's whole subject is a card that is NOT
             // rendered, and the upcoming one is the Drives tab.
             // MYR-378 adds the detail scene, which is the same Drives tab.
             .ownerReservationDormant, .ownerReservationUpcoming, .ownerReservationDetail,
             // MYR-377 — the live Scheduled tab is a rider TAB, not the map sheet.
             .riderScheduledLive,
             .ownerFreshnessStale, .ownerFreshnessWaking,
             .ownerDrivingNoNav, .ownerDrivingResolvingDestination,
             .ownerFreshnessInService, .ownerFreshnessRefused,
             .ownerServiceWindow, .ownerServiceWindowEditor, .ownerServiceWindowManual,
             .ownerServiceWindowSaved,
             .ownerRideSharePending, .ownerRideShareInService,
             .ownerRideSharePauseWarning, .ownerRideSharePauseWarningMulti,
             .ownerCharging, .ownerChargeComplete,
             .ownerVehicleEnriched,
             .ownerConnecting, .ownerConnectingCold, .ownerDrivesLoading, .ownerSettingsLoading,
             .ownerShare, .ownerShareLive, .ownerShareMessage, .ownerShareMessageNoName,
             .ownerShareEmpty, .ownerSharePendingOnly, .ownerShareAcceptedOnly,
             .ownerShareComposer, .ownerShareComposerAccess,
             .ownerShareControls, .ownerShareVehiclePaused,
             .riderSharedEmpty, .riderWatchOnly,
             .riderOwnerSelfRide, .riderVehiclesResolving, .riderVehiclesUnreachable,
             .riderInviteRateLimited, .riderInviteJoined, .riderInviteEntry:
            break // chooser / settings / sharing / rider live-map / owner scenes don't drive the viewer sheet
        }
    }
}

// MARK: - Vehicle sharing capture support (MYR-184)

/// A `VehicleSharingEndpoint` that answers from a canned script, so the five
/// sharing capture scenes can drive the PRODUCTION `LiveShareService` /
/// `LiveSharedVehicleCatalog` end to end without a server. Same precedent as
/// `DebugServiceWindowEndpoint`: inject the WIRE, run the real code path, so the
/// screenshot proves the shipping mapping rather than a hand-set view flag.
///
/// DEBUG-only, like the rest of this file.
struct DebugShareEndpoint: VehicleSharingEndpoint {
    /// MYR-369 — the rows live in a REFERENCE store, not in this struct.
    ///
    /// `patchShareInvite` has to be OBSERVABLE: the shipping
    /// `LiveShareService.patchViewer` re-reads the list after every write, so a
    /// stub that patched a value copy would answer `200`, re-read the untouched
    /// seed, and snap the switch straight back — a capture of a broken toggle,
    /// produced by a broken stub. Backing the rows with a class means the copy
    /// the service holds and the copy the scene seeded are the same rows, and the
    /// per-viewer switches are genuinely LIVE in every Share-tab DEBUG scene.
    private let store = DebugShareInviteStore()

    /// Rows the owner's per-vehicle list returns, keyed by vehicle id.
    ///
    /// `nonmutating set` so the existing `endpoint.invitesByVehicle = […]` seeding
    /// in every scene is unchanged while the storage moved underneath it.
    var invitesByVehicle: [String: [ShareInvite]] {
        get { store.rows }
        nonmutating set { store.rows = newValue }
    }
    /// Viewer rows the rider's catalog sees on `GET /api/vehicles`.
    var viewerRows: [VehicleSummary] = []
    /// What redeem answers. `nil` → the §7.5.5 happy path built from `viewerRows`.
    var redeemFailureStatus: Int?
    var redeemOwnerFirstName: String = "Alex"

    /// MYR-368 — the OWNER display name this stub server signs into `from`, or
    /// `nil` for an account Apple never handed a name for.
    ///
    /// It lives on the ENDPOINT, not on the scene's profile, because that is where
    /// it lives in production: contracts 0.22.0 puts both names INSIDE the Ed25519
    /// signature, so `from` is resolved and signed server-side and the client has
    /// no say in it. `ownerShareMessageNoName` is therefore the arm where the
    /// SERVER omitted the parameter — which is the only way that arm can exist now
    /// that the client no longer composes the link.
    var ownerDisplayName: String? = "Thomas Nandola"

    func createShareInvite(_ body: CreateShareInviteRequest, vehicleID: String) async throws -> ShareInvite {
        let expires = Date().addingTimeInterval(7 * 86_400)
        return ShareInvite(
            inviteId: "debug-created",
            vehicleId: vehicleID,
            label: body.label,
            permission: body.permission,
            status: .pending,
            code: "RBO246",
            shareUrl: DebugSignedInviteLink.url(
                code: "RBO246", expires: expires, from: ownerDisplayName, to: body.label
            ),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            expiresAt: ISO8601DateFormatter().string(from: expires)
        )
    }

    func shareInvites(vehicleID: String) async throws -> [ShareInvite] {
        invitesByVehicle[vehicleID] ?? []
    }

    func revokeShareInvite(inviteID: String) async throws {}

    func resendShareInvite(inviteID: String) async throws -> ShareInvite {
        // §7.5.4 RE-SIGNS: a new code and a new expiry mean a whole new URL, and
        // the previous link stops redeeming. This stub therefore mints the link
        // alongside the code rather than echoing the pending row's.
        let expires = Date().addingTimeInterval(7 * 86_400)
        return ShareInvite(
            inviteId: inviteID,
            vehicleId: "debug",
            label: "Mira Chen",
            permission: SharePermission(rawValue: "live_history"),
            status: .pending,
            code: "ZKQ913",
            shareUrl: DebugSignedInviteLink.url(
                code: "ZKQ913", expires: expires, from: ownerDisplayName, to: "Mira Chen"
            ),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            expiresAt: ISO8601DateFormatter().string(from: expires)
        )
    }

    func redeemShareInvite(code: String) async throws -> RedeemShareInviteResponse {
        if let status = redeemFailureStatus {
            throw RestError.http(status: status, code: nil, message: nil, subCode: nil)
        }
        return RedeemShareInviteResponse(ownerFirstName: redeemOwnerFirstName, vehicles: viewerRows)
    }

    /// `PATCH /api/invites/{inviteId}` (MYR-369), reproducing the three server
    /// behaviours that actually shape this client:
    ///
    ///  1. **PARTIAL UPDATE.** Only the properties PRESENT are written; an absent
    ///     one leaves that capability exactly as it was. A stub that assigned both
    ///     flags unconditionally would make the client's careful one-key bodies
    ///     look interchangeable with two-key ones, and hide the bug where a client
    ///     overwrites a capability the owner never touched.
    ///  2. **`permission` IS DERIVED, NEVER STORED.** The row is re-emitted with
    ///     `rides` when `allowRides` is set and `live` otherwise, so the capture
    ///     exercises the real projection instead of a tier the stub kept around.
    ///  3. **ACCEPTED ONLY.** A pending row answers `409`, exactly as the contract
    ///     says, which is what keeps the screen's "no switches until accepted"
    ///     rule honest rather than merely untested.
    func patchShareInvite(_ body: PatchShareInviteRequest, inviteID: String) async throws -> ShareInvite {
        guard let found = store.find(inviteID) else {
            throw RestError.http(status: 404, code: .notFound, message: nil, subCode: nil)
        }
        guard found.row.status == .accepted else {
            throw RestError.http(status: 409, code: .conflict, message: nil, subCode: nil)
        }
        var updated = found.row
        if let allowRides = body.allowRides { updated.allowRides = allowRides }
        if let suspended = body.suspended { updated.suspended = suspended }
        updated.permission = SharePermission(rawValue: (updated.allowRides ?? false) ? "rides" : "live")
        store.replace(updated, vehicleKey: found.vehicleKey)
        return updated
    }
}

/// Mutable row storage behind ``DebugShareEndpoint`` (MYR-369).
///
/// A class so a PATCH survives the struct copies the endpoint makes on its way
/// into `LiveShareService`. `@unchecked Sendable` over a lock rather than an
/// actor because `VehicleSharingEndpoint` is synchronous-`Sendable` and every
/// access here is a trivial dictionary read under DEBUG-only, single-scene use.
final class DebugShareInviteStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [ShareInvite]] = [:]

    var rows: [String: [ShareInvite]] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func find(_ inviteID: String) -> (row: ShareInvite, vehicleKey: String)? {
        lock.withLock {
            for (key, rows) in storage {
                if let row = rows.first(where: { $0.inviteId == inviteID }) { return (row, key) }
            }
            return nil
        }
    }

    func replace(_ row: ShareInvite, vehicleKey: String) {
        lock.withLock {
            guard let index = storage[vehicleKey]?.firstIndex(where: { $0.inviteId == row.inviteId })
            else { return }
            storage[vehicleKey]?[index] = row
        }
    }
}

// MARK: - The signed join link, minted the way the server mints it (MYR-368)

/// Builds `ShareInvite.shareUrl` in the exact shape contracts 0.22.0 specifies, so
/// the share-sheet capture scenes exercise the SHIPPING primary path — the one
/// where the payload is the server's URL forwarded verbatim — instead of quietly
/// falling back to the client-composed link and photographing MYR-359 again.
///
/// **The SIGNATURE is a stand-in and nothing else is.** Every other part of the
/// URL is derived exactly as the contract says: the parameter ORDER
/// (`k`, then `from`, then `to`), the three dot-separated parts of `k` (key id,
/// expiry as UNIX SECONDS, 86 characters of unpadded base64url standing for the
/// 64-byte signature), and the NAME SANITIZATION (first whitespace-separated
/// token, ASCII letters only, capped at 20, and the parameter OMITTED ENTIRELY
/// when nothing survives). The bytes of `k` cannot be real here — signing needs
/// the server's private key — and they do not need to be: the client never
/// verifies them, it forwards them, and what these scenes prove is exactly that
/// forwarding.
///
/// The expiry is the ROW's own `expiresAt` in a different encoding, per the
/// contract's rule that the two agree. It therefore moves with wall-clock time,
/// which is a real property of a minted link rather than an artefact — the code in
/// the capture is stable, the ten expiry digits are not.
///
/// DEBUG-only.
enum DebugSignedInviteLink {

    /// The one-character key id the contract ships today.
    static let keyID = "1"

    static func url(code: String, expires: Date, from: String?, to: String?) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = InviteLink.host
        components.path = "/\(InviteLink.pathComponent)/\(code)"

        let fromValue = signedName(from)
        let toValue = signedName(to)

        var items = [
            URLQueryItem(
                name: "k",
                value: "\(keyID).\(Int(expires.timeIntervalSince1970)).\(signature(for: code))"
            )
        ]
        // Omitted entirely when nothing survives sanitization — never emitted
        // empty. The signed payload still carries the empty string for it.
        if let fromValue { items.append(URLQueryItem(name: "from", value: fromValue)) }
        if let toValue { items.append(URLQueryItem(name: "to", value: toValue)) }
        components.queryItems = items

        return components.string ?? "https://\(InviteLink.host)/\(InviteLink.pathComponent)/\(code)"
    }

    /// The contract's server-side name rule: FIRST whitespace-separated token,
    /// stripped to `[A-Za-z]`, capped at 20, `nil` when nothing is left.
    ///
    /// Deliberately NOT `InviteLink.inviterName` — that is the CLIENT's rule for a
    /// link the client composes, and it is stricter (one non-name character drops
    /// the whole value). Reusing it here would make this stub agree with the app
    /// by construction and stop being a model of the server.
    static func signedName(_ raw: String?) -> String? {
        guard let first = raw?.split(whereSeparator: \.isWhitespace).first else { return nil }
        let letters = first.filter { $0.isASCII && $0.isLetter }
        return letters.isEmpty ? nil : String(letters.prefix(20))
    }

    /// 86 characters of unpadded base64url — the right SHAPE for a 64-byte Ed25519
    /// signature, deterministic per code so a capture of the same scene twice
    /// differs only where a real mint would differ.
    private static func signature(for code: String) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var state = UInt64(5_381)
        for scalar in code.unicodeScalars { state = state &* 33 &+ UInt64(scalar.value) }
        return String((0..<86).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return alphabet[Int((state >> 33) % 64)]
        })
    }
}

extension DebugScene {

    /// A live-shaped `VehicleSummary` viewer row, built the way the server emits
    /// one (§7.0 viewer projection: subtracts NOTHING from the owner field set and
    /// adds `sharePermission`).
    static func shareViewerRow(
        id: String,
        name: String,
        permission: String
    ) -> VehicleSummary {
        VehicleSummary(
            vehicleId: id,
            name: name,
            model: "Model 3",
            year: 2024,
            color: "Pearl White",
            vinLast4: "0001",
            status: .parked,
            chargeLevel: 72,
            estimatedRange: 210,
            lastUpdated: ISO8601DateFormatter().string(from: Date()),
            role: .viewer,
            hasActiveRide: false,
            licensePlate: "8ABC123",
            serviceEstimatedEndAt: nil,
            sharePermission: SharePermission(rawValue: permission)
        )
    }

    /// MYR-343 — an OWNED `GET /api/vehicles` row: `role: .owner` and, by §7.0,
    /// NO `sharePermission` at all (the key is emitted iff the role is `viewer`).
    /// That absence is not incidental — it is exactly why an owner produced zero
    /// grants and got routed to the invite-code prompt.
    static func shareOwnerRow(id: String, name: String) -> VehicleSummary {
        VehicleSummary(
            vehicleId: id,
            name: name,
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vinLast4: "7421",
            status: .parked,
            chargeLevel: 64,
            estimatedRange: 232,
            lastUpdated: ISO8601DateFormatter().string(from: Date()),
            role: .owner,
            hasActiveRide: false,
            licensePlate: "8ABC123",
            serviceEstimatedEndAt: nil,
            sharePermission: nil
        )
    }

    /// The OWNER's sharing service for this scene, or `nil` to leave the composed
    /// (simulated) one in place. Scoped to `ownerShareLive`, so every other owner
    /// scene keeps the fixture list and stays byte-identical.
    @MainActor
    var shareServiceOverride: (any ShareService)? {
        // MYR-347 — the state-matrix scenes stay on the SIMULATED service and
        // simply seed a different roster, because the states they capture are
        // presentation, not contract: what MYR-347 changed is how the screen
        // renders zero/one/both sections, and that is identical whichever service
        // published the rows. Keeping them simulated is also what makes them
        // cheap and deterministic (`SimulatedShareService` has no network, no
        // loading branch and no clock). The empty roster is genuinely
        // unreachable otherwise — the simulated service seeds the fixtures in its
        // `init` and always has.
        switch self {
        case .ownerShareEmpty:
            return SimulatedShareService(viewers: [], pending: [])
        case .ownerSharePendingOnly, .ownerShareComposer, .ownerShareComposerAccess:
            return SimulatedShareService(viewers: [], pending: ShareFixtures.pending)
        case .ownerShareAcceptedOnly:
            return SimulatedShareService(viewers: ShareFixtures.viewers, pending: [])
        // MYR-369 — the per-viewer control scenes. Both run the PRODUCTION
        // `LiveShareService` against `DebugShareEndpoint`'s now-MUTABLE store, so
        // every switch on the page is genuinely live: a flip runs the shipping
        // optimistic write, the real `PATCH` (partial body, derived `permission`,
        // `409` on a pending row) and the real re-read.
        //
        // They are live-path-only for a sharper reason than the rest of this
        // family: `allowRides` and `suspended` are OWNER-ONLY fields that exist
        // only on a §7.5.2 listing, so a simulated scene could draw the switches
        // but could never show them reconciling a server.
        case .ownerShareControls, .ownerShareVehiclePaused:
            return Self.shareControlsService(vehiclePaused: self == .ownerShareVehiclePaused)
        // MYR-369 — the RE-POINTED ride-share scenes build the same Share tab, and
        // differ from each other only in the WIRE their one car carries. Each is
        // the state its name has always claimed, now on the surface that renders
        // it: a car in service (the derived-off arm), a write parked in flight,
        // and the two pause-warning arms whose cars must be ride-share ON because
        // the warning is what happens on the way to OFF.
        case .ownerRideShareInService:
            return Self.shareControlsService(vehiclePaused: false, inService: true)
        case .ownerRideSharePending:
            return Self.shareControlsService(vehiclePaused: false, writeHangs: true)
        case .ownerRideSharePauseWarning, .ownerRideSharePauseWarningMulti:
            return Self.shareControlsService(vehiclePaused: false)
        default:
            break
        }
        // MYR-340 — the two share-sheet scenes reuse this endpoint verbatim, so
        // the code their resend re-mints comes off the same §7.5 wire shape.
        guard self == .ownerShareLive
                || self == .ownerShareMessage
                || self == .ownerShareMessageNoName else { return nil }
        let vehicles = VehicleFixtures.vehicles
        let expiresAt = Date().addingTimeInterval(5 * 86_400)
        let created = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 86_400))
        let expires = ISO8601DateFormatter().string(from: expiresAt)
        var endpoint = DebugShareEndpoint()
        // MYR-368 — `ownerShareMessageNoName` is the arm where the SERVER omitted
        // `from`, because with a signed link the client no longer decides. The
        // owner profile (`namesShareMessageOwner`) still differs between the two
        // scenes and still feeds the MYR-359 fallback, so the pair keeps working
        // against a pre-0.22.0 server too.
        if self == .ownerShareMessageNoName { endpoint.ownerDisplayName = nil }
        // §7.5.2 carries the signed link on every PENDING row, alongside the code
        // it contains — and on no accepted row, which is where `code` is absent
        // too.
        let pendingShareURL = DebugSignedInviteLink.url(
            code: "RBO246", expires: expiresAt,
            from: endpoint.ownerDisplayName, to: "Mira Chen"
        )
        // ONE pending invite spanning TWO vehicles on ONE code — the §7.5.1 shape
        // the screen must regroup into a single row.
        endpoint.invitesByVehicle[vehicles[0].id] = [
            ShareInvite(
                inviteId: "pen-0", vehicleId: vehicles[0].id, label: "Mira Chen",
                permission: SharePermission(rawValue: "live_history"), status: .pending,
                code: "RBO246", shareUrl: pendingShareURL,
                createdAt: created, expiresAt: expires
            ),
            ShareInvite(
                inviteId: "acc-0", vehicleId: vehicles[0].id, label: "Jonas Park",
                permission: SharePermission(rawValue: "rides"), status: .accepted,
                createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20 * 86_400)),
                acceptedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-19 * 86_400))
            ),
        ]
        endpoint.invitesByVehicle[vehicles[1].id] = [
            ShareInvite(
                inviteId: "pen-1", vehicleId: vehicles[1].id, label: "Mira Chen",
                permission: SharePermission(rawValue: "live_history"), status: .pending,
                code: "RBO246", shareUrl: pendingShareURL,
                createdAt: created, expiresAt: expires
            )
        ]
        return LiveShareService(
            api: endpoint,
            // MYR-369 — the Share tab now also holds §7.18's vehicle-level
            // switch, so it needs that seam even on scenes that are not about it.
            rideShareAPI: DebugRideShareEndpoint(),
            ownedVehicles: { vehicles }
        )
    }

    /// MYR-369's Share tab, built from the WIRE so every control on it is the
    /// shipping one.
    ///
    /// The roster deliberately spans all THREE meaningful accepted states at
    /// once, because the whole point of the redesign is that they are now
    /// independent rather than points on a ladder:
    ///
    ///   • **Jonas** — active, rides ON. Both switches on.
    ///   • **Mira** — active, rides OFF. Location on, Rides off. This is the
    ///     ordinary state and the composer's default preset.
    ///   • **Aanya** — SUSPENDED. Location off, and the Rides switch collapsed to
    ///     inert beneath it, carrying "Paused — Aanya can't see this car". Her
    ///     `allowRides` is deliberately left TRUE on the wire, which is the state
    ///     the contract is most specific about: a suspended grant with the ride
    ///     flag set grants NOTHING, and the owner's row must still show the flag
    ///     in its stored position so restoring shows what comes back. A client
    ///     that "tidied" that to false would silently downgrade her on restore.
    ///
    /// A PENDING row rides along so the "no switches until accepted" rule is in
    /// the same frame as the rows that do have them — and because `PATCH` answers
    /// `409` on it, that rule is enforced by the stub rather than merely drawn.
    ///
    /// `vehiclePaused` seeds the vehicle-level master switch OFF, which is the
    /// only way to capture the per-viewer Rides switches in their DISABLED
    /// state — the vehicle-level context the row has to explain rather than just
    /// grey out.
    /// The one car every Share-tab control scene is about. Named so the scripted
    /// reservations can be stamped with the SAME id the pause flow will ask about.
    static var shareControlsVehicleID: String { VehicleFixtures.vehicles[0].id }

    /// - Parameters:
    ///   - vehiclePaused: seeds §7.18 OFF — the only way to capture the per-viewer
    ///     Rides switches disabled by an OWNER's choice.
    ///   - inService: seeds the car IN A SERVICE BAY (MYR-358). The stored
    ///     ride-share value stays TRUE, so the switch rendering OFF is a DERIVED
    ///     off and the capture is proof of the derivation rather than of a seed.
    ///     It also puts the per-viewer Rides captions in their in-service wording,
    ///     which is the other half of what the relocation dropped.
    ///   - writeHangs: parks the §7.18 write in flight forever, for the pending
    ///     capture. The spinner is then the shipping `isBusy`, not a seeded flag.
    @MainActor
    private static func shareControlsService(
        vehiclePaused: Bool,
        inService: Bool = false,
        writeHangs: Bool = false
    ) -> any ShareService {
        let base = VehicleFixtures.vehicles[0]
        // ONE car: the Share tab's toggle card is per-vehicle, and a single-car
        // owner is the case the relocation is designed around.
        let vehicle = Vehicle(
            id: base.id, name: base.name, model: base.model, colorName: base.colorName,
            plate: base.plate, seatHeat: base.seatHeat, seatVent: base.seatVent,
            activity: base.activity,
            // The wire's own position for §7.18, read by the relocated card.
            //
            // MYR-358 — an IN-SERVICE car keeps this TRUE on purpose. The capture
            // is only proof of anything if the switch it shows OFF is one the
            // server says is ON; seeding `false` would render an identical frame
            // for the wrong reason and would still pass with the derivation gone.
            rideShareEnabled: vehiclePaused ? false : true,
            isInService: inService
        )
        let day = 86_400.0
        func stamp(_ offset: Double) -> String {
            ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset))
        }
        let endpoint = DebugShareEndpoint()
        endpoint.invitesByVehicle[vehicle.id] = [
            ShareInvite(
                inviteId: "acc-jonas", vehicleId: vehicle.id, label: "Jonas Park",
                permission: SharePermission(rawValue: "rides"),
                allowRides: true, suspended: false, status: .accepted,
                createdAt: stamp(-20 * day), acceptedAt: stamp(-19 * day)
            ),
            ShareInvite(
                inviteId: "acc-mira", vehicleId: vehicle.id, label: "Mira Chen",
                permission: SharePermission(rawValue: "live"),
                allowRides: false, suspended: false, status: .accepted,
                createdAt: stamp(-12 * day), acceptedAt: stamp(-11 * day)
            ),
            ShareInvite(
                inviteId: "acc-aanya", vehicleId: vehicle.id, label: "Aanya Iyer",
                permission: SharePermission(rawValue: "live"),
                // Suspended WITH the ride flag still set — see above.
                allowRides: true, suspended: true, status: .accepted,
                createdAt: stamp(-8 * day), acceptedAt: stamp(-7 * day)
            ),
            ShareInvite(
                inviteId: "pen-diego", vehicleId: vehicle.id, label: "Diego Vega",
                // A PENDING row carries NEITHER flag — the keys are omitted while
                // there is no grant to describe, which is exactly the absence the
                // screen must render as "no switches yet" rather than as "off".
                permission: SharePermission(rawValue: "rides"), status: .pending,
                code: "RBO246",
                shareUrl: DebugSignedInviteLink.url(
                    code: "RBO246", expires: Date().addingTimeInterval(5 * day),
                    from: "Thomas Nandola", to: "Diego Vega"
                ),
                createdAt: stamp(-2 * day), expiresAt: stamp(5 * day)
            ),
        ]
        return LiveShareService(
            api: endpoint,
            // `.hangs` is the pending capture's whole mechanism — see
            // `DebugRideShareWriteOutcome`.
            rideShareAPI: writeHangs
                ? DebugRideShareWriteOutcome.hangs.endpoint
                : DebugRideShareEndpoint(),
            ownedVehicles: { [vehicle] }
        )
    }

    /// The RIDER's shared-vehicle catalog for this scene, or `nil` to leave the
    /// composed (simulated) one in place.
    @MainActor
    var sharedCatalogOverride: (any SharedVehicleCatalog)? {
        var endpoint = DebugShareEndpoint()
        switch self {
        case .riderSharedEmpty:
            // Zero viewer rows — the honest empty map.
            endpoint.viewerRows = []
        case .riderWatchOnly:
            // ONE grant on the LOWEST tier: watchable, not requestable.
            endpoint.viewerRows = [Self.shareViewerRow(id: "shared-1", name: "Alex\u{2019}s Model 3", permission: "live")]
        case .riderInviteRateLimited:
            endpoint.redeemFailureStatus = 429
        case .riderInviteJoined:
            // A MULTI-VEHICLE invite, so the success card's "+1 more vehicle"
            // line — real information the fixture host never had — is in frame.
            endpoint.viewerRows = [
                Self.shareViewerRow(id: "shared-1", name: "Alex\u{2019}s Model 3", permission: "live_history"),
                Self.shareViewerRow(id: "shared-2", name: "Alex\u{2019}s Cybercab", permission: "live_history"),
            ]
        case .riderOwnerSelfRide, .riderSettingsOwned:
            // MYR-343 — the client's account: ONE owned row, ZERO viewer rows.
            // `role: .owner` carries no `sharePermission` at all (§7.0 emits the
            // key iff the role is `viewer`), which is precisely why it produced no
            // grant and shunted him to the invite prompt.
            //
            // MYR-354 reuses the SAME injected list for the Settings tab, so the
            // two scenes are one account seen from its two surfaces.
            endpoint.viewerRows = [Self.shareOwnerRow(id: "owned-1", name: "Lunar")]
        case .riderSettingsMixed:
            // MYR-354 — an account holding BOTH. Owned first is the rendered
            // order regardless of the wire order, so the owner row is deliberately
            // NOT first on the list the server hands back.
            endpoint.viewerRows = [
                Self.shareViewerRow(id: "shared-1", name: "Alex\u{2019}s Model 3", permission: "rides"),
                Self.shareOwnerRow(id: "owned-1", name: "Lunar"),
                Self.shareViewerRow(id: "shared-2", name: "Mom\u{2019}s Model Y", permission: "live"),
            ]
        case .riderSettingsEmpty:
            // MYR-354 — the ONE account the empty state is true of.
            endpoint.viewerRows = []
        case .riderVehiclesResolving:
            // MYR-343 — the list is parked in flight and never answers, so the
            // shell holds its `.resolving` skeleton for the whole capture. Same
            // "never resolve it" device as `DebugLoadingFleet`.
            return LiveSharedVehicleCatalog(api: endpoint, listVehicles: {
                try await Task.sleep(for: .seconds(86_400))
                return []
            })
        case .riderVehiclesUnreachable:
            // MYR-343 — the list throws, so the production `load()` records the
            // failure WITHOUT claiming the account is empty. Nothing is hand-set:
            // the screen is whatever the shipping `RiderVehicleSet.resolve` makes
            // of `hasLoaded == false, loadFailed == true`.
            struct ListUnreachable: Error {}
            return LiveSharedVehicleCatalog(api: endpoint, listVehicles: { throw ListUnreachable() })
        default:
            return nil
        }
        let endpointCopy = endpoint
        return LiveSharedVehicleCatalog(api: endpointCopy, listVehicles: { endpointCopy.viewerRows })
    }

    /// Whether the invite-code screen should submit the sample code on appear.
    /// Headless capture tooling cannot type six characters into the hidden field,
    /// so this is the same stand-in-for-a-tap precedent as `initialRefreshPhase`
    /// and `opensServiceWindowEditor`.
    var autoSubmitsInviteCode: Bool {
        self == .riderInviteRateLimited || self == .riderInviteJoined
    }

    /// MYR-340 — whether the Share tab should open the SYSTEM SHARE SHEET on
    /// appear, by running the production resend against the first pending invite.
    ///
    /// The sheet is otherwise unreachable headlessly: it opens only behind a
    /// Resend → confirm → Resend tap chain (or a full compose + Send), and capture
    /// tooling can neither tap nor type. Seeding the TAP rather than the RESULT is
    /// deliberate and follows `autoSubmitsInviteCode` — the code in the capture is
    /// minted by `LiveShareService.resend` off the real §7.5.4 wire, and the text
    /// is built by the shipping `ShareInviteMessage`, so the screenshot is
    /// evidence about the product rather than about a literal in this file.
    ///
    /// Scoped to the two MYR-340 scenes, so `ownerShareLive` keeps its untouched
    /// tab render and stays byte-identical.
    var opensShareSheetForFirstPending: Bool {
        self == .ownerShareMessage || self == .ownerShareMessageNoName
    }

    /// MYR-347 — which composer step the Share tab should boot with open, or
    /// `nil` for every other scene (which is all of them but two, so the whole
    /// existing set is byte-identical).
    ///
    /// Same stand-in-for-a-tap precedent as `autoSubmitsInviteCode` /
    /// `opensServiceWindowEditor`: the composer is behind a tap, and its second
    /// step is behind a tap plus typing, neither of which headless capture
    /// tooling can perform. The scene seeds only the ENTRY — the step is then
    /// rendered by the shipping composer, and `.access` arrives through the
    /// shipping `openConfig()`, so its keyboard dismissal, its vehicle
    /// pre-selection and its default tier are all the real ones.
    enum ComposerEntry { case recipient, access }

    var initialComposerEntry: ComposerEntry? {
        switch self {
        case .ownerShareComposer: .recipient
        case .ownerShareComposerAccess: .access
        default: nil
        }
    }

    /// What the `.access` composer scene types into the recipient field.
    ///
    /// TWO values because the field means two different things: LIVE takes an
    /// owner-typed LABEL (§7.5.1 — never resolved to an account), SIM takes an
    /// EMAIL and derives the display name from it (`ShareFixtures.name(fromEmail:)`,
    /// screens.jsx:1237-1240). Seeding one string for both would fail the
    /// shipping `validRecipient` on whichever path it did not suit — and the
    /// scene runs that real validation on the way in, which is the point.
    static let sampleComposerLabel = "Mira Chen"
    static let sampleComposerEmail = "mira.chen@example.com"
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
