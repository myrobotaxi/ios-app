# MyRoboTaxi iOS — agent guide

Native SwiftUI port of the MyRoboTaxi design prototype. Two roles (owner / rider) share one design kit.

## Canonical sources (in priority order)

0. **`design/` in this repo** — a synced mirror of the design project for
   agents (the DesignSync tool does not exist in subagent sessions). Read
   `design/README.md` first; if a file you need isn't mirrored yet, say so in
   your report instead of guessing.
1. **Design project** (claude.ai design, DesignSync MCP — orchestrator only, projectId `019e19a0-1707-77b7-a71e-97e4f5ed5769`):
   - `Handoff for Claude Code.md` — the rebuild spec (tokens, buttons, flows, overlays, motion). Read it before any UI work.
   - `app/*.jsx` + `app/tokens.js` — prototype source; every color/radius/animation resolves to a real definition here.
   - `Anatomy.html` (renders `ds/anatomy-*.jsx`) — labeled exploded screens; `screenshots/` — reference renders.
   - `ds/ds-data.jsx` — canonical DEVIATIONS / OPEN_QUESTIONS. The `decisions` copy in `app/surfaces.jsx` is **stale** (wrongly says Google auth retained — auth is Apple-only). See MYR-194.
2. **Linear**: P9 — iOS App (SwiftUI). One issue per PR; use the issue's `gitBranchName`. Backend readiness is stated per issue — do not invent API calls for backends marked NOT ready.
3. **Contracts**: `myrobotaxi/contracts` — all payload models are generated (MYR-96). Never hand-write a wire shape. How this is consumed: `Packages/MyRoboTaxiKit` (M2, MYR-21) depends on `https://github.com/myrobotaxi/contracts.git` from `0.5.0` and imports `MyRobotaxiContracts` (generated Codable/Sendable types — `VehicleState`, WS envelope/messages). Screens never touch JSON or define payload structs; they consume typed models from the Kit. M1 screens use fixture data only — no contracts, no network.

## Hard rules

- **Flat only** (product decision, Thomas 2026-07-06) — the app ships the
  **Flat** look exclusively; Liquid Glass is out of scope. Do not build glass
  variants, glass styling, or look toggles. The `MRTSurfaceLook` API exists in
  DesignSystem but the app pins `.flat` at the root; when the prototype's
  `useSurfaces()` offers flat + liquid styles, port **only the flat branch**
  (e.g. Button uses the flat variant table + the `flat`/goldDeep styles).
- **Tokens only** — every color/font/radius/spacing comes from the DesignSystem package (ported from `app/tokens.js` `window.T`). No hardcoded hex in screens. Gold `#C9A84C` is the sacred accent — CTAs, active nav, marker, route, brand; never decorative.
- **Reuse, don't fork** — `Button(variant:)` (6 variants), ConfirmDialog, SuccessToast, BottomSheet are built once (MYR-162) and consumed everywhere. `outline-draw` is reserved for ride-request CTAs only.
- **M1 is simulated** — screens ship on fixture data matching the prototype's mocks (`VEHICLES`, `DRIVES`, `VIEWERS`, `PENDING`, `REQUESTED_RIDES`, `SCHEDULED_RIDES`). No network in M1.
- **No fixtures on the live path** (MYR-228) — fixture/mock data (`RideRequestFixtures`, `ShareFixtures`, `VehicleFixtures`, `DriveFixtures`, `RideHistoryFixtures`, hardcoded personas like "Alex"/"Sam"/"Jordan" or fake ETAs) may render **only** when `AppMode` is `.simulated` or under a `#if DEBUG` scene. A **live** surface (`AppMode.live` / `seams.isLive`) with no ready backend must render an **honest empty state**, never fixture data. Gate every fixture seed on the ONE resolved `AppMode` (thread `mode.live != nil` / `seams.isLive` from `RootView.init`, following MYR-214/228) — do NOT invent new env vars, and keep the `.simulated`/DEBUG-scene experience pixel-identical (the drift-gate scenes depend on the fixtures).
  MYR-184 closed the last three leaks in this class, all of them on sharing surfaces: `InvitesScreen`'s vehicle picker read `VehicleFixtures` unconditionally (so a live owner shared cars that were not on their account); `InviteCodeFlow`'s success screen hardcoded `InviteHostFixture`; and `SharedViewerState.vehicle` **defaulted** to `VehicleFixtures.vehicles[0]` with no gate whatsoever — the worst of the three, because a default is invisible at the call site. The lesson generalizes: **a fixture DEFAULT is a live-path leak with no grep signature.** Prefer `nil` + an explicit adopt over a fixture default on anything a live path can construct.
- **Honor Reduce Motion** — traces/pulses/shimmers fall back to static.
- **Full-bleed geometry** (MYR-196) — the prototype is a full-bleed 393×852
  canvas; every offset in `screens.jsx`/`components.jsx` (`top: 60`,
  `padding: '74px …'`, `bottom: 26`, …) is a distance from the **PHYSICAL
  screen edge**, not from SwiftUI's default safe-area insets. Screens must
  ignore the relevant safe area and place chrome at the prototype's absolute
  offsets — e.g. `MapHeader` top **60**, screen headings top **74**,
  `BottomNav` bottom **26** — measured from the true top/bottom of the
  device, not from the status-bar/home-indicator-inset container. Building
  inside the default safe area silently stacks the OS inset on top of the
  prototype offset (e.g. a "60pt from top" chip landing ~119pt down, or a
  "26pt from bottom" nav floating ~60pt up) — the MYR-196 punch-list bug.
  Prefer one shared placement helper per chrome element (e.g. `mrtBottomNav()`
  in DesignSystem) over re-deriving the offset per screen.
- **Study the prototype BEFORE writing code** — for any screen/flow work, first run the local prototype (see drift gate below), navigate to your screen in **Flat** mode, and walk every state and animation you're about to build (drag the sheets, trigger the dialogs, run the flow end-to-end). Write down the states you observed; build to that, not to your reading of the jsx alone.
- **Drift gate (AFTER)** — before a screen PR is done: (1) run the actual prototype locally (`cd design && python3 -m http.server 8722`, open `http://127.0.0.1:8722/prototype.html` via the chrome-devtools MCP tools — see `design/README.md`; **switch Appearance to Flat first, every time**), (2) drive your screen to each of its states there and capture a **FULL-FRAME** screenshot (the entire simulator screen / entire prototype phone frame — never a cropped region: cropping is exactly how the MYR-196 physical-edge-vs-safe-area drift slipped through review), (3) capture the same states as **FULL-FRAME** screenshots in your simulator build, (4) compare full frame vs. full frame — layout, spacing, colors, AND motion (sequence/duration/curve per Handoff §8 + the `@keyframes`, including Reduce Motion fallbacks), (5) put the side-by-side full-frame comparison + verdict in the PR body. Also cross-check the screen's `Anatomy.html` callouts.
- Min tap target 44pt. Hero numbers use `.monospacedDigit()`. Dark-appearance-only asset catalog.

## Structure

- `App/` — app target. `Packages/DesignSystem/` — tokens, type scale, `Surface` modifier, buttons, overlays, primitives. `Packages/MyRoboTaxiKit/` — thin REST + telemetry-WS client on contracts types (M2, MYR-21): `RestClient`, the actor `TelemetrySocket`, and the `@Observable LiveVehicleState` bridge; Swift-6 concurrency-clean, no third-party deps. `design/` — read-only synced design mirror.
- The app renders **Flat** (solid `surface` + hairline) everywhere — see the flat-only hard rule.

## Build

Requires full Xcode (Command Line Tools alone cannot build iOS targets).

- **Project generation: XcodeGen** (decided in MYR-161). The `.xcodeproj` is **not** checked in — `project.yml` is the source of truth. After cloning or whenever targets/sources/settings change, run `xcodegen generate` (install: `brew install xcodegen`), then build:
  `xcodebuild -project MyRoboTaxi.xcodeproj -scheme MyRoboTaxi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- DesignSystem package tests (run from `Packages/DesignSystem/`, the project-level package scheme has no test action): `xcodebuild -scheme DesignSystem -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`
- MyRoboTaxiKit package tests (run from `Packages/MyRoboTaxiKit/`, same reason — no test action on the project-level package scheme): `xcodebuild -scheme MyRoboTaxiKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`
- App target: `MyRoboTaxi`, bundle id `app.myrobotaxi.ios`, iOS 17 deployment target (Liquid Glass gates on iOS 26+ via `#available`), portrait iPhone only, forced dark (`UIUserInterfaceStyle: Dark`).

### Debug scene hooks (MYR-200)

A permanent `#if DEBUG` env-gated jump table (`App/Sources/Debug/DebugScenes.swift`, applied in `RootView.init`) boots the app straight into any ride-flow state for the drift-gate captures — no hand-driving the flow, no per-round scaffolding. **Release builds never compile it** (whole file + call sites are `#if DEBUG`), so shipping is unaffected.

Launch with the `SIMCTL_CHILD_MRT_SCENE` env var (`simctl launch` strips the `SIMCTL_CHILD_` prefix and forwards it as `MRT_SCENE`):

```sh
xcrun simctl install booted "$(path/to)/MyRoboTaxi.app"
SIMCTL_CHILD_MRT_SCENE=search xcrun simctl launch booted app.myrobotaxi.ios
xcrun simctl io booted screenshot search.png   # full-frame, never window automation
```

A `-MRT_SCENE <name>` launch **argument** is accepted as a fallback for tooling that can't set the child env. **Scene names** (unset = normal Sign-In boot):

- Rider request flow: `idle`, `search`, `searchFiltered`, `searchSelected` (destination chosen, "Continue" CTA), `pinDrop`, `pinDropRealPath` (MYR-217: boots to idle, then auto-drives the REAL idle→search→Continue→pinDrop transition with live updates flowing — use this, not cold `pinDrop`, to probe pin-drop entry camera behavior), `review`, `reviewPicker`, `booking`, `pending` (minimized "Request sent" pill), `trackingLeg1` (to pickup), `trackingLeg2` (in-ride), `trackingArriving`, `summary`, `declined`, `riderBusyVehicle` (MYR-233: the Review sheet with an UNAVAILABLE vehicle — muted Busy chip on the fleet row, gold instant CTA replaced by "Schedule with … instead". Select the state with `MRT_BUSY_REASON=busy|inService|offline|paused`, default `busy`; each is built from real wire inputs through `LiveFleetMemberMapping`, so the capture exercises the shipping predicate. **MYR-342 adds `paused`** — the owner's ride-share switch off (`rideShareEnabled: false`) on a car that is otherwise PARKED and healthy, which is the whole point of the state. It is the one reason whose CTA area holds **no button at all**: the muted "Paused" chip and the helper line "{Owner} has paused ride requests right now", and nothing else. The other three keep MYR-233's "Schedule with … instead" route because each ENDS on its own; an owner's pause is open-ended and the server refuses scheduled rides against it too, so offering scheduling would be a `409 vehicle_unavailable` with extra steps), `riderPlateChip` (MYR-286: the Booking sheet's plate chip carrying the REAL owner-entered plate instead of the `VIN ····xxxx` degrade — same live-shaped `VehicleSummary` path, with `licensePlate` set), `riderScheduleFloored` (MYR-316: the Schedule slide-up card with the SERVICE-WINDOW FLOOR applied — a muted "Lunar is in service until Sat, Aug 1 · 2:00 PM" caption, dimmed-but-visible day/time chips for every slot before the car is back, and a selection already pulled forward to the first bookable one. Injects a live-shaped in-service `VehicleSummary` carrying `serviceEstimatedEndAt` through the REAL `LiveFleetMemberMapping`, then opens the card via the existing one-shot `opensScheduleOnSearch` hook, so the capture exercises the shipping `RideScheduleFloor` grid rule rather than a hand-set flag. **A vehicle with NO window imposes NO floor** — that is the common case and every other rider scene is byte-identical), `riderScheduleBooked` (MYR-385: the SAME Schedule card dimmed for the OTHER reason — §7.22's booked windows rather than MYR-316's service floor. The car is PARKED with no window, so every dimmed chip in the frame came from the conflict read; it injects the wire through `DebugBookedWindowsEndpoint` and runs the shipping store + `RideScheduleFloor`, and carries the rider's OWN noon reservation plus somebody else's PENDING 5:30 PM so both captions are reachable from one scene. Capture at t≈0.3s for the pre-arrival / fail-open frame and t≈1.5s for the settled one — see "A rule the picker cannot see is indistinguishable from a bug" below).
`riderIdleETA` / `riderIdleETABusy` (MYR-341) — the rider idle sheet's ROTATING
  search placeholder carrying a real "A ride is 9 min away", and the same scene
  with the availability gate tripped (static "Where to?"). Both are
  live-path-only by construction: the line needs a device fix, a watched-vehicle
  coordinate and an available live fleet member at once, behind a real auth
  session. They seed only the three INPUTS — a device fix through MYR-248's
  existing `simulatedUserFix` hook, a vehicle coordinate through
  `SharedViewerState.debugVehicleCoordinateOverride`, and a live-shaped
  `FleetMember` built by the REAL `LiveFleetMemberMapping` — and let the shipping
  `RiderPickupETA` quantize, estimate and gate, so the number in the capture came
  from the production estimator rather than a literal. Like
  `ownerFreshnessStale`, they force exactly ONE live branch
  (`debugResolvesLivePickupETA`) on an otherwise simulated boot, so the Home/Work
  quick chips are still in frame; everything about the placeholder is the live
  render. **Capture at t≈1.2s for "Where to?" and t≈3.6s for the ETA line** —
  `RotatingPlaceholder` alternates on 2800ms. `idle` itself keeps the fixture "3
  min" line and stays byte-identical.

`riderNoRides` / `riderNoRidesFleet` (MYR-352) — the rider idle sheet carrying the
  muted **"no rides" banner** above the search bar. `riderNoRides` is the
  SINGLE-vehicle set and reuses `riderBusyVehicle`'s own
  `MRT_BUSY_REASON=busy|inService|offline|paused` selector plus its live-shaped
  `busyFleetMember`, so all four reason-specific headlines AND both
  scheduling-line branches come out of one scene, built from real wire inputs
  through the REAL `LiveFleetMemberMapping`. `riderNoRidesFleet` is the
  MULTI-vehicle set (one car in service, one offline) — the input that selects the
  generic headline, and the one thing `debugFleetMemberOverride` cannot express.
  Both are live-path-only by construction, so `idle` and every other rider scene
  stay byte-identical.

`riderRecentDestinations` (MYR-356) — the SEARCH sheet's pre-typing region carrying
  the rider's own **recent destinations**. It is `search` VERBATIM plus one seeded
  store, so the pair is a clean before/after of exactly the RECENT section: `search`
  shows the four prototype fixtures standing in for a history that did not exist,
  this shows the five real rows that take their place the moment one does. The scene
  seeds **six** and the shipping `RecentDestinationList.capped` renders five,
  most-recent-first, so the capture is the cap and the ordering rather than an
  illustration of them. It is also the ONE search scene that boots with the
  **keyboard down** (`suppressesSearchAutoFocus`) — its subject sits below three
  Saved rows and MYR-250's auto-focus covers it; `search` keeps the auto-focus and
  is byte-identical.

`riderScheduledReview` (MYR-389) — the Review sheet carrying a COMMITTED SCHEDULE,
  i.e. the one whose CTA reads **"Schedule with {owner}"** rather than "Request
  from {owner}". `review` VERBATIM plus one field (`draftSchedule`), so the pair is
  a clean one-field diff. It exists because that CTA's scheduled branch is the
  ENTRY POINT of MYR-389's defect, and unlike every other rider scene it
  deliberately arms the simulated service's REAL timers instead of holding still:
  the leak only becomes visible ~13.6s later, when the request auto-accepts, the
  pending pill stands down and the greeting card's "Where to?" comes back.
  `RiderDraftLifetimeUITests` drives it.

`riderScheduledReviewRealPath` (MYR-390) — the SAME sheet, **arrived at rather than
  seeded**. It boots that draft on SEARCH, waits for MKDirections and the whole
  1.6s etch to finish (`DebugScene.reviewEtchSettleAllowance` after the route
  lands, not a stopwatch — MKDirections answered in 1s on one simulator run and
  3.5s on the next), then drives the shipping `proceedFromSearch()`. MYR-390's
  defect is a TRANSITION, so a cold `review` scene can only ever photograph a
  first arrival — MYR-217's rule pointed at the etch. `RouteEtchContinuityUITests`
  samples the map band across the flip.

`reviewLongDistance` (MYR-395) — `review` VERBATIM except for the two ENDPOINTS:
  the client's own r16 trip, Grayslake IL → Galleria Dallas TX. A cross-country
  pair is not a bigger version of `review`'s 18.4 mi SFO run — it is the input that
  puts ~7,300 MKDirections vertices through the etch overlay, and the only route by
  which his "no line at all" frame can be photographed. **On its own it ETCHES
  NORMALLY** (MKDirections answers that pair in ~1.0s), which is half the triage
  verdict; pair it with `MRT_ROUTE_UNAVAILABLE=1` for the reported frame. `review`
  itself is byte-identical, so the two are a clean two-coordinate diff.

- Rider scheduled-ride sheet: `scheduledDetails`, `scheduledReschedule`, `scheduledRequested`, `scheduledConfirmCancel`.
- Owner side: `ownerHome`, `ownerDrives` (Drives tab, `initialOwnerTab` "drives"), `ownerIncoming`, `ownerIncomingQueued` (MYR-317: the SAME incoming card with the queue badge up — a muted "+2 more waiting" chip trailing the "INCOMING RIDE REQUEST" kicker, the owner's only signal that resolving this card is not the end of the queue. The simulated service has no incoming FEED, so the count comes from its DEBUG-only `debugSeedWaitingIncoming`; the live service derives the identical number from the held incoming page. Everything else is `ownerIncoming` verbatim, so the pair is a clean before/after of exactly the chip — `ownerIncoming` itself stays pixel-identical), `ownerScheduled`, `ownerScheduledLive` (MYR-312/313: the SCHEDULED incoming card on the **live** branch, in the client's condition — Saturday 5:30 PM reservation, target car IN SERVICE now. The only scene that forces `HomeScreen`'s live rendering (`DebugScene.rendersLiveIncomingRequest`), because the real requester name and the scheduled accept-gate exemption are both live-only branches a sim capture can't reach; it injects an in-service `DebugVehicleDetailsFleet` the seeded record targets by id, so the real fleet join + the real `isAcceptGated` predicate both run. `ownerScheduled` stays simulated and pixel-identical), `ownerVehicleEnriched` (MYR-320: the vehicle-details section with every enrichment field populated off ONE live-shaped snapshot — Model "2026 Model Y Performance" composed from the display-ready `trimLabel` while the snapshot ALSO carries the raw `trim` badge "p74d" it must NOT substitute, Color "Quicksilver" flowing through the EXISTING `VehicleState.color` with no mapping change, and an "FSD" row reading "FSD (Supervised) v14.3.5" verbatim directly after Software. `ownerVehicleDetails` keeps the pre-enrichment shape — blank color, no FSD row — so the pair is a clean before/after. Pair with `MRT_OWNER_DETENT=half`), `ownerServiceWindowManual` (MYR-320: the same in-service car as `ownerServiceWindow`, with the renamed "Service completion date" row carrying its manual sub-caption "Set manually — Tesla hasn’t provided an estimate for this visit". That caption is reachable only when a READ ISSUED AFTER a save comes back agreeing with what the owner stored — proof Tesla held no `service_etc` to outrank it (MYR-362 moved the comparison there from the write echo, which by §7.16's design is the owner's own column and so agrees unconditionally). Headless tooling cannot perform the save+read pair, so the scene seeds the provenance THROUGH the shipping `LiveVehicleCommandExecutor.provenance` classifier. The wire carries NO source discriminator, so a cold read renders no caption at all), `ownerVehiclePlate` (MYR-286: the Vehicle details section with a real owner-entered plate on BOTH read surfaces — pair with `MRT_OWNER_DETENT=half`; the same scene without a plate is `ownerVehicleDetails`, which now shows the "Add plate" affordance rather than an uneditable VIN), `ownerServiceWindowSaved` (MYR-316, client defect: the owner saved a completion date, the server persisted it, and the sheet kept showing the old state. The same in-service car whose snapshot carries **NO** window — the state the sheet is in when the editor opens — with the production `LiveVehicleCommandExecutor.setServiceWindow` run against `DebugServiceWindowEndpoint` on boot and **nothing refetching the snapshot afterwards** (the field is snapshot-only by contract). Everything the capture shows about the window therefore came from the write ECHO, through the unified `VehicleServiceWindow.resolvedEndAt`; before the fix both read surfaces took the still-empty snapshot and this scene rendered no line and no time at all. Capture at PEEK for the hero line, pair with `MRT_OWNER_DETENT=half` for the row), `ownerNoticeRejected` (MYR-301, client defect: "The car didn’t accept that" stuck forever. A real 502 `command_failed` on `auto_conditioning_stop` settles the real `.rejected` notice, which now clears itself after `LiveVehicleCommandExecutor.defaultNoticeDisplayDuration` (6s) — so capture at t≈2s and t≈8s, the same two-shot pattern `ownerDispatchedCompleted` uses. **That bounded display applies to `ownerNoticeCharge`/`ownerNoticeAsleep`/`ownerNoticeSeat` too**: take their captures inside the window. Pair with `MRT_OWNER_DETENT=half`), `ownerNoticeRejectedInService` (MYR-329, client defect: the SAME rejection with the reason NAMED. Jul 28: "Any reason why car didn't accept climate, is it because low battery?" — the car was in service mode and the battery was fine, but `ownerNoticeRejected`'s generic "The car didn't accept that" left a wrong guess as the only guess available. Same 502 `command_failed` on `auto_conditioning_stop`, same real `LiveVehicleCommandExecutor`, same real `.rejected` settle — the ONE difference is that the wire error carries the server's canonical token in `message` (`"vehicle command failed: vehicle_in_service"`, rest-api.md §7.9), so the shipping `RestError.commandRejectionReason` parse runs and the row reads "Car is in service — commands are limited". Nothing about the notice is hand-set. The tile sub stays "Declined" for every reason — the reason lives on the full-width row, which has the space to say it properly. It needs its own scene because `ownerNoticeRejected` is MYR-301's lifecycle capture and stays byte-identical, and because this state has no other capture route at all: it takes a car genuinely sitting in service mode, behind a real auth session, refusing a real command. The pair is a clean before/after of exactly that one line. Same TWO-SHOT bounded display — t≈2s and t≈8s. Pair with `MRT_OWNER_DETENT=half`), `ownerVehicleSeatsHeatOnly` (MYR-308: the seat section for a car whose REST SPEC says it has NO cooled seats — `DebugVehicleDetailsFleet(ventedSeatReadBacks: true, seatCoolingCapable: false)` carries BOTH the cooler read-backs that make the MYR-299 presence heuristic fire AND the contracts-0.16.0 `seatCoolingCapable: false` that authoritatively overrules it, so the capture is the precedence proof: "SEAT HEATING", flame-only rows, and no Heat↔Cool toggle at all — not even a greyed-out one, which would imply hardware the car lacks. Pair with `MRT_OWNER_DETENT=half`), `ownerMediaNowPlaying` (MYR-303: the Media card with a REAL now-playing block off the wire — title/artist/album/source plus a real duration + sane elapsed, mapped by the production `VehicleContractMapping.nowPlaying` and reconciled by the real `LiveVehicleCommandExecutor`. Shows the shipping render: the prototype media card's title/artist grammar, a PASSIVE progress line (no thumb — §7.9 has no seek-to-position), no invented cover art (the wire carries no artwork), and a live transport row whose icon is the car's own `Playing`), `ownerMediaNoSession` (MYR-314: the same card with NO media session — the car cleared the title to `""` and reports no `mediaPlaybackStatus`. Both halves of one real situation: the honest idle line instead of the track that just ended, and the muted, non-interactive transport row with "Start media in the car first". Pair both media scenes with `MRT_OWNER_DETENT=half`), `ownerFreshnessStale` / `ownerFreshnessWaking` (MYR-315: the owner sheet's tappable **freshness stamp**, which is **LIVE-ONLY** — the prototype has no recency element in the sheet hero at all, and a simulated snapshot carries no `isStreaming`/`lastUpdated` to be honest with, so on the simulated path the stamp is never constructed and every other owner scene stays byte-identical. Both scenes inject `DebugFreshnessFleet` — a car OFFLINE for 7h whose live-shaped `VehicleState` travels the production `VehicleContractMapping`, so the stamp shown is the one the shipping resolver produced — and force `HomeScreen`'s live branch via `DebugScene.rendersLiveVehicleFreshness`. `ownerFreshnessStale` is the resting "Synced 7h ago"; `ownerFreshnessWaking` is the in-flight "Waking Lunar…", seeded as a phase (`initialRefreshPhase`) because headless capture tooling can't synthesize the tap. Capture at PEEK — where the stamp matters most, since the tile qualifiers + "Not live" footer only exist at half, below a scroll — or pair with `MRT_OWNER_DETENT=half`), `ownerFreshnessInService` / `ownerFreshnessRefused` (MYR-345, the client's own screenshot AKXUQLSW…: the SAME in-service fleet `ownerServiceWindow` injects — so that scene stays byte-identical — with the stamp's live rendering forced on, so the peek hero carries BOTH live-only qualifier lines at once. No scene reached that pair before, and it is the only variant where the flat 24pt reserve was visibly wrong. It is also the DEAD-TAP repro: a car read "just now" is already current, so the tap resolves to the acknowledgement — the branch that rendered NO copy at all until this issue. `ownerFreshnessRefused` is the same car read 7h ago, whose §7.15 call the server refuses BY NAME (`502 command_failed` + MYR-329's `vehicle_in_service` token, held 1.5s so the in-flight phase is a real state); capture at t≈1s for "Waking Model Y…" and t≈4s for the named settle. **A refusal the server explained must be explained to the owner** — silence is the bug even when the refusal is correct), `ownerServiceWindow` / `ownerServiceWindowEditor` (MYR-316: the owner's side of the service window, injected as `DebugVehicleDetailsFleet(status: .inService, serviceEstimatedEndAt: <next Sat 2 PM>)` — the instant rides BOTH read surfaces (live-shaped snapshot AND list row) exactly as a real server emits it and travels the production `VehicleContractMapping` folds. `ownerServiceWindow` is the READ: the In Service badge with a muted "Service Estimated Completion · Sat, Aug 1 · 2:00 PM" directly beneath it, best captured at PEEK where the line lives; pair with `MRT_OWNER_DETENT=half` to also see the Status & location card's matching In Service chip + the "Expected back" row. `ownerServiceWindowEditor` is the WRITE: the same car with the entry sheet already presented, seeded via `DebugScene.opensServiceWindowEditor` because the row lives inside a half-detent scroll that headless tooling cannot tap — the same stand-in-for-a-tap precedent as `ownerFreshnessWaking`. Its Save runs the production `LiveVehicleCommandExecutor.setServiceWindow` against `DebugServiceWindowEndpoint`, which reproduces the two server behaviours that shape the client: future-only validation, and (MYR-362) the **owner-column echo** — §7.16 answers with `expectedEndAt`, the instant just stored, and Tesla precedence is a READ concern that surfaces on the next §7.0/§7.1 fetch. Both scenes leave every other owner scene byte-identical: a car that is not in service renders no line and no row), `ownerRideSharePending` / `ownerRideShareInService` (MYR-342/MYR-358, **RE-POINTED TO THE SHARE TAB BY MYR-369** — the owner's ride-sharing switch MOVED off the Status & location card, so these boot `initialOwnerTab` "invites" and read the relocated card at the TOP of the Share tab. `ownerRideShareOn` / `ownerRideSharePaused` are RETIRED: `ownerShareControls` / `ownerShareVehiclePaused` already capture that exact on/off pair on the new surface. `ownerRideSharePending` is the write IN FLIGHT and has no other capture route — against a real backend it lasts milliseconds, so the scene parks the write inside a stub that never answers (`DebugHangingRideShareEndpoint`) and flips on appear through the SHIPPING `setVehicleRideShare`; the spinner is the real `VehicleRideShareRow.isBusy` and the switch already reads its new position because the flip is OPTIMISTIC. `ownerRideShareInService` is the DERIVED-OFF arm and the regression guard for it: an in-service car renders the switch OFF, inert and captioned "Off while in service — resumes automatically" while the stored value stays explicitly TRUE on the wire — seeding `false` would render an identical frame for the wrong reason. Both are live-path-only; `MRT_OWNER_DETENT` no longer applies to either, since neither opens the owner sheet), `ownerDispatchedCompleted` (MYR-292: owner Home holding a `completed` ride — boots with the "Dropped off ✓" banner UP; the 5s auto-dismiss then acknowledges the ride on `OwnerHomeState`, so capture at t≈2s and t≈8s to get both halves. The acknowledgement is owner-scoped state, NOT `HomeScreen` @State, so it survives the tab switch that used to bring the banner back).

- Vehicle sharing (MYR-184): `ownerShare` (the owner Share tab on the SIMULATED path, carrying the fixture roster — three accepted viewers with their presence dots and one pending invite. **MYR-347 REDESIGNED WHAT IT RENDERS** — see "The Share tab is client-directed" below — so it is now the MIXED arm of that issue's state matrix rather than the prototype's own render, and is byte-stable from MYR-347 forward), `ownerShareLive` (the SAME tab against rest-api.md §7.5. Four differences, all of them the contract asserting itself: the pending caption names the **CODE** — "Code RBO246 · sent 2d ago" — because §7.5 has no email anywhere; that row carries the **TIER** the owner chose, which the prototype's `doSend` discarded outright; the accepted viewer's presence dot is **OFF**, since v1 ships no presence signal and the row must not claim someone is watching; and ONE pending row stands for a MULTI-VEHICLE invite — two server rows sharing one code — which is the §7.5.1 regrouping running for real), `riderSharedEmpty` (the rider Live Map with ZERO shared vehicles — a state that could not exist before this issue, because `SharedViewerState.vehicle` defaulted to `VehicleFixtures.vehicles[0]` with NO live gate, so a signed-in rider who had redeemed nothing watched a map captioned "Cybercab", a car on nobody's account, ticking fixture telemetry. The honest render has no map at all), `riderWatchOnly` (§7.5.0 — the rider idle sheet for a viewer BELOW the `rides` tier: the gold "Where to?" search bar is replaced by a muted "You can watch {car}" line, because the server will 403 a ride create from this tier and the client must not offer what will fail), `riderInviteRateLimited` (§7.5.5 — the invite-code screen refusing on the RATE LIMIT. Deliberately NOT the shake: nothing is wrong with the code, and clearing + shaking would say "wrong code" and send the rider off to ask for a new one. The entry stays and a quiet line says to wait), `riderInviteJoined` (the invite success screen built from a REAL `RedeemShareInviteResponse`. It used to hardcode `InviteHostFixture` — "Alex's Model Y · Roommate", a person and a car that exist nowhere. On a MULTI-VEHICLE invite, so the "+1 more vehicle" line is in frame, and with the capability line reflecting the ACTUAL tier instead of promising rides unconditionally).

  MYR-347 adds five SIMULATED scenes to this family — `ownerShareEmpty`,
  `ownerSharePendingOnly`, `ownerShareAcceptedOnly`, `ownerShareComposer`,
  `ownerShareComposerAccess`. They stay on `SimulatedShareService` deliberately:
  what that issue changed is how the screen renders zero / one / both sections,
  and that is identical whichever service published the rows, so a simulated
  scene is the cheap deterministic capture and a live one would only add a
  clock. See "The Share tab is client-directed" below.

  All six of the ORIGINAL sharing scenes are **live-path-only and unreachable from a simulated capture by construction**: `SimulatedShareService` mints no code (so no share sheet, no code caption, no tier line) and `SimulatedSharedVehicleCatalog` always holds three `rides`-tier grants with a redeem that cannot fail (onboarding.jsx:421's forgiving check). They inject `DebugShareEndpoint` and run the **production** `LiveShareService` / `LiveSharedVehicleCatalog` against it — the same "real code path, injected wire" precedent as `DebugServiceWindowEndpoint` — so what the capture shows came from the shipping grouping, tier mapping and gates, not a hand-set flag. The two invite-code scenes also set `autoSubmitsSampleCode`, because headless tooling cannot type six characters into the hidden field (the same stand-in-for-a-tap precedent as `ownerFreshnessWaking`). Nothing consults these overrides unless the scene is one of the six, so every existing scene is byte-identical.

  **The share payload is ONE LINK** (MYR-340 → MYR-346 → MYR-359 → **MYR-368**) — scenes
  `ownerShareMessage` / `ownerShareMessageNoName`. MYR-184 handed the recipient
  the code and nothing else; MYR-340 wrapped it in a mini-onboarding paragraph
  (steps, TestFlight link, bare code line, expiry) after the client's *"Feels
  strange just sending a text message, where do they go"*; MYR-346 moved the
  invite's own link to the head of that paragraph so the FIRST link in the body
  would be the one platforms preview. The client came back on 2026-07-30: the
  branded card still never showed. **iMessage's rule is not "preview the first
  link" — it is "a message that is NOTHING BUT a link becomes a rich link"**, so
  the prose written to introduce the card was what suppressed it.
  `ShareInviteMessage.shareURL` now returns exactly
  `https://myrobotaxi.app/join/{CODE}?from={Name}` and `InvitesScreen` hands it
  to `UIActivityViewController` as a **`URL` activity item, not a `String`** —
  the item TYPE is half the fix, since a string that happens to be a URL is
  still a body of text. Still **no `LPLinkMetadata`/`NSItemProvider`**: the
  sheet's preview is the system's to compose, and interposing an item source is
  exactly how a pure-URL payload stops being one.

  **Nothing was lost with the paragraph**, which is the only reason it could go:
  a phone WITH the app never read it (the AASA hands the link to
  `InviteLinkRouting`, the code prefills and auto-submits), and a phone without
  it lands on the page at the other end, which carries the code, a copy button,
  the TestFlight button and the same steps — server-rendered, and a better
  version of every line the message held. `AppDistribution
  .testFlightPublicJoinURL` survives as the ONE home for the build link (ASC ⇢
  TestFlight ⇢ **Friends & Family**; **capped at 100 testers**, undetectably
  from the client) but is **asserted ABSENT from the payload**, which is what
  keeps the demotion from quietly reversing.

  **`?from=` is the two grammars, moved to where they are read.** The opening
  line used to switch between named and first-person in Swift; the page now
  titles itself "{Name} invited you to ride their Tesla" or falls back to the
  generic line, in the OG card AND the heading (both server-rendered, since
  scrapers never run JS). `InviteLink.inviterName` decides what may travel: the
  value must be **letters plus name punctuation only** (space, hyphen,
  apostrophe, period), which are then dropped — "Mary-Jane" → `MaryJane` — and
  the result capped at 20. **One character that is not a name character drops
  the whole parameter**, never a scrubbed remnant: `Thomas3` is not evidence the
  owner is called Thomas, and `<script>alert(1)</script>` reduced to its letters
  would put "scriptalertscript invited you…" in a page title. A name carrying
  non-ASCII letters ("José", "Ольга") is omitted whole rather than misspelled to
  a stranger — `[A-Za-z]` is the web's accepted alphabet, so widening it means
  widening both sides. The page filters again, independently, on arrival: neither
  side trusts the other. `UserProfile.firstName` is genuinely nil for anyone
  Apple did not name on the FIRST authorization, and that case simply omits the
  parameter — never `?from=`.

  **The parser ignores the query, and that is now load-bearing** — every link
  the app hands out carries one, so `InviteLink.code(from:)` reading the code
  from the PATH regardless of query is what keeps the app's own links working
  (`InviteLinkParsingTests`). `InviteCodeEntry.extractCode` gained a matching
  pass 0: a pasted `/join/{CODE}` link is read STRUCTURALLY through the same
  parser rather than scanned, because the token heuristic sees two six-character
  candidates on `?from=Thomas` and would lose the coin toss for an all-letter
  code.

  **MYR-368 — THE LINK IS THE SERVER'S NOW, AND IT IS SIGNED.** Everything above
  about the payload's SHAPE is unchanged and is why the card renders; what
  changed is who WRITES the URL. contracts **0.22.0** puts `shareUrl` on the
  pending `ShareInvite` — the complete link, minted and signed server-side as
  `/join/{CODE}?k={kid}.{exp}.{sig}&from={Owner}&to={Recipient}`, where `k` is an
  Ed25519 signature over `join:{code}:{exp}:{from}:{to}` that the web join shell
  verifies **statically** against a compiled-in public key, with no database and
  no round trip. An unsigned, forged or tampered link is bounced at the shell
  before it can reach an endpoint that would act as a code oracle.

  - **That makes the URL INDIVISIBLE, which is the whole client-side rule.** BOTH
    display names are inside the signature, so there is no such thing as taking
    the server's code and attaching our own `?from=` — the result carries no `k`
    at all. `ShareInviteMessage.shareURL(serverURL:code:ownerFirstName:)` forwards
    the string VERBATIM: not re-composed, not re-ordered, not re-encoded, not
    host-checked, not stripped of parameters. The owner's local
    `UserProfile.firstName` is **ignored** whenever a server link exists, and that
    is asserted across the whole name matrix.
  - **The fallback is the contract's instruction, not defensive coding** — "a
    consumer that finds `code` without `shareUrl` MUST fall back". Here that is
    MYR-359's client-composed unsigned link, byte for byte what shipped before,
    so the transition is graceful in both directions (an old app against the new
    server composes its own; a new app against the old server does too). The
    shell only bounces a link that CLAIMS a signature and fails it.
  - **`URL(string:)` SUCCEEDING IS NOT EVIDENCE THAT A STRING IS A LINK**, and
    the first implementation believed it was. Foundation parses RFC 3986 RELATIVE
    references, so `URL(string: "not a url at all")` returns a URL whose
    `absoluteString` is `not%20a%20url%20at%20all` with a nil scheme and a nil
    host — and handing that to `UIActivityViewController` puts percent-escaped
    TEXT in the thread, which is MYR-359's defect wearing a `URL` type. The guard
    is **absoluteness** (a scheme AND a host) and deliberately stops there: it
    does not pin the host, the path, the parameter set or the presence of `k`,
    because the link's address is the server's to move (with the AASA and the
    entitlement — MYR-346) and a client that silently downgraded a valid new
    shape to its own unsigned link would turn a coordinated rollout into a
    regression nobody can see.
  - **A resend RE-SIGNS**, so `LiveShareService.resend` takes the link off the
    §7.5.4 RESPONSE rather than off the pending row it resent — new code, new
    expiry, whole new URL, and the previous LINK stops redeeming along with the
    previous code.
  - **Both parsers were already right, and both are now pinned on a full signed
    vector.** `InviteLink.code(from:)` reads the PATH, so the 86-character
    base64url signature — a long run of code characters and their `_`/`-`
    neighbours — cannot influence it. `InviteCodeEntry.extractCode`'s pass 0 is
    where this pays: on a signed link the token heuristic sees the signature
    shattered into runs by its own separators, and it picks the first
    six-character run that mixes letters and digits, which inside a base64url
    blob is a coin toss it has no business taking. An **all-letter code inside a
    signed link** is the sharpest case and is asserted.
  - **The capture scenes had to move or they would have photographed the
    fallback.** `DebugShareEndpoint` mints a link through `DebugSignedInviteLink`
    — the contract's exact shape (parameter ORDER `k`, `from`, `to`; `k` =
    keyId.expUnix.86-char-base64url; the server's own name rule) with a
    stand-in signature, since signing needs the server's private key and the
    client never verifies it anyway. Without that, `ownerShareMessage` /
    `ownerShareMessageNoName` would keep exercising the pre-0.22.0 path while
    looking exactly right. **`ownerShareMessageNoName` is now the arm where the
    SERVER omitted `from`** (`DebugShareEndpoint.ownerDisplayName = nil`), which
    is the only way that arm can exist once the client no longer composes the
    link; `to=Mira` stays on both, so the pair is still a one-parameter diff.
    The `k` expiry is the row's own `expiresAt` in UNIX seconds (the contract
    requires them to agree), so it moves with wall-clock time — the code in a
    capture is stable, the ten expiry digits are not.
  - **The stub follows the SERVER's name rule, not the client's stricter one.**
    `InviteLink.inviterName` omits "José" whole; the contract strips to
    `[A-Za-z]` and sends `Jos`. Making the stub agree with the app would have
    made it a mirror of this client instead of a model of the server, and the
    difference would then be invisible in every capture.

  ONE presentation still serves BOTH the create and the resend path (`doSend`
  and `resendDialogConfig` both just set `handout`). Both scenes are
  live-path-only (SIM mints no code, so it never opens a share sheet at all) and
  run the **production** `LiveShareService.resend` against `ownerShareLive`'s own
  `DebugShareEndpoint` on appear, because the sheet is otherwise behind a Resend
  → confirm → Resend tap chain headless tooling cannot perform.
  `ShareInviteMessageUITests` proves the sheet PRESENTS over the real
  activity-item plumbing and stops there — the preview row is system-composed for
  a URL item, so asserting on it would be asserting on iOS; the delivered bytes
  are pinned exactly by `ShareInviteMessageTests` (MYR-350: a UI test must never
  read `UIPasteboard`).

  **"What is shared with me" is not "what can I ride"** (MYR-343) — scenes
  `riderOwnerSelfRide` / `riderVehiclesResolving` / `riderVehiclesUnreachable`.
  MYR-184 gated the rider shell's empty state on `grants.isEmpty`, i.e. on
  SHARES. An **owner** in rider mode has zero `role: viewer` rows by definition,
  so an account that owns a Tesla outright was told it had none and sent to
  redeem an invite code — the client's *"When I switched to rider mode as an
  owner I briefly saw the rider home page and then it prompted me to enter a
  code."* Self-rides are a supported flow (MYR-325 tested one live), and the ride
  path never had the bug: `RiderLiveVehicleLocator` has always taken
  `vehicles.first` regardless of role. Only the shell gate and the adopted map
  vehicle regressed. `SharedVehicleCatalog` now publishes BOTH partitions of the
  one §7.0 list it already fetches — `grants` (viewer rows) and `ownedVehicles`
  (owner rows, which carry no `sharePermission` at all) — and
  `RiderVehicleSet.resolve` is the ONE rule over them. **Owned wins**: an account
  holding both self-rides its own car, because a share can sit on `live` and
  would otherwise hide the "Where to?" CTA from someone who owns a Tesla, and
  because the FleetMember the request is actually created against is
  `vehicles.first` — adopting a shared car onto the map would put two different
  vehicles on two halves of one flow. The empty state now means what its copy
  says: no vehicles AT ALL.

  **The flash was the two-way boolean.** `hasLoaded && grants.isEmpty` has no
  arm for "not asked yet", so that case fell through to the rider home and then
  swapped. Three genuinely different situations cannot be told apart by one flag,
  so one of them always borrows another's surface for a frame. The shell now
  switches on the whole resolution and presents NOTHING until it resolves —
  `RiderVehiclesLoadingSkeleton`, shaped like the idle greeting sheet at its own
  `sharedIdleSheetHeight` and wearing the same `RiderIdleSheetBackground` (that
  surface was promoted out of `SharedViewerScreen` rather than copied, because a
  second copy of its gradient is a second place to forget MYR-226's NaN guard).
  The fourth arm is `.unavailable`: a list that did not answer is **not**
  "nothing is shared with you" and **not** a skeleton either (MYR-326: loading ≠
  unavailable, and nothing is in flight behind it) — it is the honest
  "Can't reach your vehicles right now", recovered by a resume re-asking, with no
  retry button, exactly as the owner's cold-read timeout is. All three scenes are
  live-path-only by construction (`SimulatedSharedVehicleCatalog.hasLoaded` is
  `true` from the first frame and it owns nothing, so it resolves to the same
  first grant it always did), and every simulated + DEBUG rider capture is
  byte-identical — `riderSharedEmpty` is the pair's BEFORE half and differs from
  `riderOwnerSelfRide` by exactly one owned row on the injected list. Capture the
  skeleton twice (once with Reduce Motion) to prove `MRTShimmerBand`'s fallback:
  5 distinct block renderings across 6 frames with motion on, 1 of 6 with it off.

  **ONE Settings grammar, and rider Settings answers "do I have a car?"**
  (MYR-354) — scenes `ownerSettingsTop` / `riderSettingsOwned` /
  `riderSettingsMixed` / `riderSettingsEmpty`. Three TestFlight items, Jul 30:
  owner and rider Settings are *"inconsistent in terms of UI/UX"* (reported from
  BOTH directions), and *"Showing no vehicles shared with me… I own a vehicle so
  would it appear here or no? Because technically I can request a ride from
  it."*

  **The split was the PROTOTYPE's, not the port's.** `screens.jsx`'s
  `SettingsScreen` and `shared-screens.jsx`'s `SharedSettingsScreen` are two
  different list idioms drawn by one design kit — plain rows on the page ground
  separated by full-bleed `<Divider>`s, row content at the page gutter, a bare
  "PROFILE" label, gold text links floating under each list, sign-out as bare
  red text; versus inset CARDS, row content at 16, an avatar + role-badge
  profile card, gold ACTION ROWS inside the card, sign-out as a full-width
  outlined button. The port was faithful to both and inherited the split whole.
  **The card grammar wins** — it is the inset-grouped list Settings.app itself
  uses, it is already this app's dominant grammar everywhere else (Status &
  location, vehicle details, drive-summary stats, every dialog and sheet), and a
  full-bleed hairline on a near-black ground says "a new region starts here"
  without saying which rows belong to it. `App/Sources/Screens/Settings/
  SettingsGrammar.swift` is that grammar ONCE (`SettingsCard`,
  `SettingsSectionLabel`, `SettingsDetailRow`, `SettingsActionRow`,
  `SettingsToggleRow`, `SettingsProfileCard`, `SettingsSignOutButton`,
  `SettingsFooter`) and both screens are assembled from it, so a future row
  cannot re-fork them.

  - **`ViewerRow` bakes the PAGE GUTTER**, because it was built for the
    full-bleed owner list and is shared with the Share tab, which is still a
    full-bleed page. MYR-347 owns `ShareRows.swift`, so owner Settings consumes
    the row EXACTLY as it is and corrects the difference at the call site
    (`MRTSettingsGrammar.viewerRowCardInset` = `pageGutter - 16` = 8, applied as
    a negative inset; the row draws nothing in its padding band, so the 8pt that
    lands outside the card clips harmlessly). **When that restyle lands the
    constant goes to 0 and nothing else on either page changes** —
    `SettingsGrammarTests` pins the arithmetic.
    **#138 (MYR-347) has since merged and the constant STAYS 8**: that redesign
    moved the Share tab to `ShareRosterViews` and left `ViewerRow` deliberately
    untouched (it deleted only `PendingRow`, which had one consumer), so the row
    still bakes the page gutter and owner Settings is still its only caller. The
    handoff is not spent — it is simply still open, pointing now at whoever
    restyles `ViewerRow` itself.
  - **A real port defect fell out of the audit**: rider Settings' section labels
    ("SHARED WITH ME", "NOTIFICATIONS") were CENTRED — a bare `Text` in a
    `VStack` with no leading alignment — where both prototypes put them at the
    gutter. The shared `SettingsSectionLabel` fixes it, and it is one of only
    two changes to that page's pixels (the other is the mode-switch row growing
    2px to the 44pt tap floor); every other ink band is byte-identical.
  - **The vehicle section is built ON TOP of MYR-343's rule, not beside it.**
    `RiderSettingsVehicleSection.resolve` takes the same four inputs
    `RiderVehicleSet.resolve` does and DEFERS to it for the empty/unavailable
    verdict, so the empty state renders **iff the shell would also resolve
    `.empty`** — asserted across the whole matrix, which is what stops the tab
    and the map ever again giving one account two different answers. Owned rows
    lead (same precedence, same reason: the ride is created against
    `vehicles.first`), the label switches to **"Vehicles"** the moment one is
    owned because "Shared with me" is simply FALSE of the lead row, and the
    owned row reads `{name}` / "Your car · Ride from it anytime" behind a gold
    `car.fill`. A list still in flight claims NOTHING (a settings section
    shimmering on its own would be motion about a list nobody is waiting for);
    a list that FAILED gets the shell's own sentence verbatim.
  - Every SIM + DEBUG rider capture keeps the prototype's three personas and its
    "Shared with me" label, because `SimulatedSharedVehicleCatalog
    .ownedVehicles` is empty. The three new rider scenes are live-path-only by
    construction, the same `DebugShareEndpoint` route MYR-343's scenes take —
    `riderSettingsOwned` injects the SAME one-owned-row list `riderOwnerSelfRide`
    does, so the pair is one account seen from its two tabs.
  - **TWO SWITCHES, ONE PREFERENCE** (added to MYR-354 from MYR-349's prefs
    findings, PR #137). `ride_lifecycle` is ONE §7.19 category and no send site
    distinguishes "accepted / declined" from "pick-up & arrival", so the rider's
    two prototype rows were one preference wearing two masks — flip either and
    both move, and the untouched one appears to change by itself. They are ONE
    row now, **"Ride updates" / "Accepted, declined, pick-up and arrival"**; the
    sub-line is the receipt for the merge, naming everything the single switch
    governs. The same category gates the OWNER's "X wants a ride" pushes and the
    owner page had no switch for them at all, so **"Ride requests"** now LEADS
    that section — the prototype's four are all about the car, this one is about
    the ride-hailing loop.

    **#137 has since merged, and the two handoffs it was written against both
    held.** (1) The copy lived in `SettingsNotificationCopy` precisely so #137's
    `SettingsNotificationRows` could absorb it **as a table edit**, and that is
    what happened: the table now carries "Ride requests" at the HEAD of `owner`
    (5 rows, on `rideLifecycle`) and ONE merged `rider` row reading its label and
    its new optional `caption` from the same enum, so the row→category mapping and
    the row COPY are one fact in one place, and both screens `ForEach` over it.
    (2) `SettingsSectionNotices` was the named slot for exactly this: #137 shipped
    `PushPrefsNotice` loose in each body, the merge moved it INTO the slot above
    `PushDeniedNotice` on both pages, and `SettingsGrammarTests
    .testTheNoticesSlotRendersWhatItIsGiven` measures the slot through a
    `UIHostingController` — **0pt with nothing to say** (which is what keeps every
    simulated + DEBUG capture pixel-identical, since `SimulatedPushPrefsService
    .statusMessage` is always nil) and taller for each notice that has something to
    say. A view moved into a container is exactly the change that compiles while
    rendering nothing, so it is measured rather than reasoned about.

    #137's "Tips & product news" deletion **stands**: the row is gone from the
    rider table, so the rider card is ONE row. The state behind all of this is
    #137's `PushPrefsService` — the local `NotificationToggles` structs both
    screens carried are deleted on both pages, including the `rideRequests` /
    `rideUpdates` fields MYR-354 had added to them, because `ride_lifecycle` was
    always an ACCOUNT value and never a view's.

  - **`ownerSettingsTop` exists because half the owner page had no capture route
    at all**: `ownerSettings` boots scrolled to its bottom anchor (MYR-224's
    switch row is below the fold and headless tooling cannot scroll), and this
    issue changes the half above it. `ownerSettings` keeps its anchor and its
    role as the pair's other end.

  **"{Owner}'s {Vehicle}" is conditional, not concatenated** — `VehicleSummary.name` is the owner's OWN nickname and owners name cars after themselves (the canonical server fixture is literally `"Alex's Model 3"`), so prefixing §7.5.5's `ownerFirstName` onto it produced **"Alex's Alex's Model 3"**, which the first `riderInviteJoined` capture showed verbatim. `SharedVehicleTitle.compose` prefixes the owner only when the nickname is not already about them. The §7.0 catalog rows carry **no owner name at all** — only the redeem response does, and only at join time — so "Shared with me" titles on the vehicle nickname alone rather than persisting a name that can go stale.

- Account deletion (MYR-355, App Store Guideline 5.1.1(v)) and the **VISUAL
  OFFBOARDING FLOW** (MYR-366, **CLIENT-DIRECTED**): `ownerDeleteAccount` /
  `riderDeleteAccount` (the ONE dialog, per role — the title is shared and the
  consequence sentence is not, which is the whole reason the copy is role-split),
  `ownerOffboarding` (the STEPPER: capture at t≈1.4s mid-narration and t≈5s at the
  honesty gate), `offboardingFailed` (the delete refused, the narration stopped
  where it stood), `ownerOffboardingDone` / `riderOffboardingDone` (the two
  endings; the owner's illustrations LOOP on 3s, so take two frames ~1.5s apart).
  All six drive the SHIPPING `AccountDeletionFlow` through `debugDrive`, which
  calls the same methods a thumb does in the same order — the stand-in-for-a-tap
  precedent of `ownerFreshnessWaking` / `ownerServiceWindowEditor`, and a stand-in
  for the TAPS only. **Which state an offboarding scene lands on is decided by the
  WIRE it injects, never by a flag**: all four run `.offboarding` and differ only in
  what `DebugScene.accountDeletionEndpoint` hands them (a call that never answers, a
  delayed scripted `500`, or the simulator's own absent endpoint, which IS the
  `204`), so a capture shows the shipping state machine reconciling a real answer
  rather than a hand-set phase. All six carry `ownerSettings`/`riderSettings`'s own
  DEBUG identity (`showsLiveSettings`) and start at each list's bottom anchor.
  `riderSettings` itself is deliberately NOT given that anchor.

  **MYR-366 RETIRED three MYR-355 scenes ON PURPOSE** — `ownerDeleteAccountConfirm`
  / `riderDeleteAccountConfirm` went with the second dialog they captured, and
  `deleteAccountFailed` is superseded by `offboardingFailed`, which shows the same
  refusal on the surface it now happens on.

```sh
SIMCTL_CHILD_MRT_SCENE=ownerDeleteAccount xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=ownerOffboarding xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=offboardingFailed xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=ownerOffboardingDone xcrun simctl launch <udid> app.myrobotaxi.ios
```

  **The client's report, Jul 30**: *"the delete account is weird. It shows the
  email again even though its displayed at the top of the settings — follow a more
  clean design for delete account and it needs to be a visual offboarding flow with
  visually showing the user as they are offboarded all the steps to offboard them.
  Kind of like a clean vertical stepper where each circle animates as a check mark
  … and animated visuals in the end to demonstrate how to unpair the tesla virtual
  key, etc anything else manual required."* His stated priority for this surface,
  verbatim: **"security, transparency, and trust is top of mind."**

  **THE EMAIL WAS SHOWN THREE TIMES, AND THE CAUSE IS A FALLBACK NOBODY LOOKS AT.**
  `UserProfile.settingsDisplayName` is `name ?? email ?? "Your account"`, and Apple
  hands the NAME over **only on the FIRST authorization** — so for any account
  signed in before that (his, and every re-installed tester's) the display name IS
  the email address. `SettingsProfileCard` then rendered it as the name AND as the
  email, and MYR-355's Account-section name row rendered it a third time. The row is
  **deleted on both pages** and the section is now exactly one thing, the way out of
  the product; identity heads the page, once, in the card built for it
  (`AccountDeletionUITests.testTheAccountSectionNoLongerRepeatsTheIdentity` is the
  guard). `nameProvenanceCaption` went with it. **The lesson generalizes: a display
  fallback that substitutes one field for another makes every surface that renders
  both a duplicate, and no call site shows it.**

  **THE HONESTY GATE IS THE WHOLE DESIGN.** There is exactly ONE network call and
  it either answers `204` or it does not; six server events do not exist. So the
  stepper **NARRATES** the teardown sequence the endpoint is documented to perform,
  and the gate is drawn where it can be verified — in `OffboardingStepperState`,
  as one expression:

  - Every step EXCEPT the last may check on the clock alone (`narrationLimit` is
    `stepCount - 1`, so adding a step extends the NARRATED part and leaves the gate
    where it is).
  - The LAST step ("Account deleted") and the "done" state check **only** after the
    real `204` — `checkedCount` returns the full count solely when the server
    succeeded AND the narration has caught up.
  - A `204` that lands EARLY cannot jump the final check forward; a narration that
    finishes early holds a real `SpinnerRing` on the last step.
  - A failure STOPS the narration where it stood (`canNarrate` is false the moment
    a failure is recorded). **An all-checked stepper over a failed delete is
    unreachable by construction rather than by care**, which is what
    `testAFailureAtAnyPhaseRendersHonestlyAndNeverAllChecked` sweeps — every phase,
    both roles.

  **A failed delete leaves you SIGNED IN**, unchanged from MYR-355 and now with the
  retry ON the offboarding screen, beside the stepper that shows how far it got.
  `DELETE /api/users/me` is re-runnable by contract, so **retry RESUMES**: the steps
  already checked are not un-checked, because un-checking would claim the previous
  attempt undid itself.

  **The wipe moved from the `204` to Done.** The two manual Tesla steps are the last
  thing an owner will ever be told about this account; wiping the shell the instant
  the server answered would take that screen away before it was read.

  **The confirmation is ONE dialog now, not two.** It absorbed the second's
  permanence sentence and dropped the half that repeated the consequences already
  listed ("…and deletes your account" one tap above "Your account … will be
  permanently deleted"). The confirm button is MYR-355's own `"Delete permanently"`
  and the dismiss its `"Keep my account"` — that tap IS the point of no return. The
  ROW keeps "Delete account", so the row opens a question and the button answers it
  (MYR-355 made them identical deliberately; with one dialog that reasoning
  inverts). Still **not a type-to-confirm**: the guideline wants deletion
  discoverable and confirmable, and a labyrinth is its own review risk. **There is
  no rename affordance** and there must not be one — the backend has no
  profile-update endpoint at all (asserted by `AccountDeletionUITests`).

  **Motion is the design kit's own grammar, not new numbers.** Each circle
  OUTLINE-DRAWS (`Circle().trim` from 12 o'clock, 0.22s) then CHECK-DRAWS
  (`MRTCheckDrawShape`, 0.18s) — `mrtCheckDraw`'s stroke-dashoffset,
  onboarding.jsx:225 — summing to the client's **0.4s per step**. `CheckDrawShape`
  was `private` inside `AddTeslaFlow`; it is promoted to DesignSystem as
  `MRTCheckDrawShape` and both consumers read it, because a second hand-transcribed
  copy of a path from a jsx file is a second place to transcribe it wrongly. The
  stagger is the narration's own interval, which is **derived** from
  `narrationDuration` (3.2s) rather than fixed per step — so an owner sees six steps
  in the same time a rider sees four, and `stepInterval ≥ checkDuration` is asserted
  so the beats can never pile up. **Reduce Motion → instant checks.**

  **The endings are pure SwiftUI shapes on the token palette — no assets.** The
  owner's two illustrations (a car touchscreen losing the MyRoboTaxi key row; a
  third-party-apps list whose MyRoboTaxi switch turns off) are per-frame
  `TimelineView(.animation)` renders on ONE shared 3s period — **not**
  `offset`-animated masked layers, per MYR-326/MYR-337's lesson that a masked band
  can composite once and never re-render. **Reduce Motion renders the static
  END-STATE frame** (key gone, toggle off), because the end state is what the reader
  has to recognise on their own screen. Proven by frame-diff, never by a still:
  **7 distinct illustration renderings across 12 frames with motion on, 1 of 12 with
  it off** (`simctl spawn <udid> defaults write com.apple.Accessibility
  ReduceMotionEnabled -bool true`). A RIDER has neither step — nothing of theirs was
  enrolled in a car and they never authorized Tesla — so their ending is the
  check-hero and stops; an "optional next steps" section with nothing in it is the
  MYR-347 empty-section defect on a screen someone reads once.

  **Vehicle-removal parity.** Removing the owner's LAST/only car leaves exactly the
  state deleting the account leaves, so MYR-258's confirm gains the same two manual
  steps as a **compact static** card in the MYR-360 content slot —
  `CompactManualOffboardingSteps`, reading the same `ManualOffboardingStep` values
  the ceremony does, so the menu paths are one fact in one place. It is deliberately
  not the animated version: a confirm dialog is a question, and a looping animation
  inside one competes with the buttons. The confirm's prose summary of the two steps
  was DELETED with the move — a summary directly above the thing it summarises is
  the stacked chrome MYR-347 was about. **TWO PRESENTATIONS, NOT ONE WITH AN `if`
  INSIDE THE SLOT**: a conditional inside the `@ViewBuilder` types the slot as
  `Optional<…>`, which is not `EmptyView`, so the card would spend the slot's 14pt
  top padding even on the nil branch and move MYR-258's dialog — exactly what
  MYR-360 documented that type check for. Splitting on the BINDING keeps the
  not-last-car dialog byte-identical. It has **no headless capture route** (it needs
  the live teardown seam behind an open vehicle-detail sheet); the guard is a
  `UIHostingController` measurement that the card fits `dialogMaxWidth - 40`.

  **`requesterName` absent now means the account was DELETED.** The server omits
  the key if and only if the rider has no identity row in any of the three
  sources; a rider who exists but is nameless resolves to the literal `"Rider"`.
  So the two surfaces that stand in for a MISSING NAME — the incoming sheet's
  title and the accept-toast / reserved-ride label — read **"Former rider"**, not
  "Shared viewer", which asserts in the present tense a role the person no longer
  holds. `IncomingRequestDisplay.neutralRole` survives UNCHANGED for the one
  surface that renders it unconditionally as a ROLE subtitle even when a name IS
  present (`IncomingRequestSheet.headerSubtitle`, ride-request.jsx:1313), and
  MYR-360's pause warning keeps its own "A rider". Unreachable from SIM by
  construction, so every simulated capture is byte-identical.

- Loading states (MYR-326, all **live-path-only**): `ownerConnectingCold` (owner Home in the first moments of a live boot — the `GET /api/vehicles` list is still in flight, so NOTHING is known and even the switcher chip is a placeholder), `ownerConnecting` (**the client's state**: the list landed — his car's name is known and the REAL `MapHeader` renders it — and the cold `/snapshot` has not. MYR-319's 0/0.8/3/9s retry means this routinely lasts >10s on an asleep/in-service car, which is why he screenshotted it; before this issue both scenes were one black screen with a system `ProgressView` and "Connecting to your vehicles…"), `ownerDrivesLoading` (Drives tab, first page in flight — a day heading + three `DriveRow`-shaped placeholders where a spinner and "Loading drives…" used to be), `ownerSettingsLoading` (Settings ⇢ Tesla Account with the fleet list in flight — two row-shaped placeholders instead of "Connecting…"; forces the LIVE linked-vehicle branch via `DebugScene.rendersLiveLinkedVehicles`, the same stand-in-for-a-live-session precedent as `showsLiveSettings`, so `ownerSettings` itself stays byte-identical). All four inject `DebugLoadingFleet`, which parks the app in ONE loading branch and never resolves it — these states have no other capture route, since on a healthy account each lasts milliseconds and the client's needs a real asleep car behind a real auth session. **No simulated scene can reach a skeleton at all**: `SimulatedVehicleFleet.isConnecting` and `SimulatedDrivesFeed.isLoading`/`hasMore` are `false` by construction and Settings only consults the live list when `linkedVehicles` is wired, so the whole drift gate is untouched. Capture each one twice — once normally, once with `xcrun simctl ui <udid> reduce_motion enabled` — to prove the Reduce Motion fallback: the blocks stay, the sweep goes (`MRTShimmerBand` renders nothing).

**Loading ≠ unavailable** (MYR-326) — skeletons render only from genuinely-in-flight branches. The honest end states keep their quiet one-liners and must never be skeletonized: "No drives yet", "No vehicles linked to this account", "Sign-in required to load vehicles", and the new cold-read timeout. **MYR-386 adds the converse, which is the more common defect: an honest end state must never be rendered BEFORE the fetch that would justify it.** The owner Share tab spent two issues resolving from two arrays that start `[]`, so an in-flight list and a genuinely empty one produced the same definitive, CTA-bearing hero — see "A published loading signal that no screen read" below. The check that catches this class is not "does the loading state exist" but "**can the empty state be reached from a phase that is not `loaded`**". That timeout is what makes the rest safe: `LiveVehicleFleet` now bounds the cold `/snapshot` wait to `ColdSnapshotLoad.budget()` (the Kit's whole retry schedule + per-attempt slack, ~21s) and then renders "Can't reach <car> right now" instead of loading forever. Before it, a car that never answered left `isConnecting` true for the whole session — survivable as a spinner, a lie as a shimmering placeholder. Recovery is the existing low-friction one (a resume re-asks; a late snapshot clears the timeout by itself), not a retry button.

**THE HONEST END STATE WAS UNREACHABLE, AND THE MAP WENT TO NULL ISLAND**
(MYR-387, client defect, build `202607311129`) — scenes `ownerColdReadFailed` /
`ownerNoFixMap`. TestFlight, Jul 31: owner Vehicle tab with the Lunar chip up, a
**completely black map area** and the sheet stuck on skeleton rows. *"Nothing
loading, what happened?"* His car was `in_service` and NOT STREAMING; `GET
/api/vehicles` and `/snapshot` both answered fine from the backend, and a
Share-tab screenshot from the same minute proves the device had network and a
session. Three defects, each of which alone produces part of that frame.

- **1. THE COLD SNAPSHOT WAS GATED ON THE WEBSOCKET.**
  `TelemetrySocket.fetchAndEmitSnapshot` had exactly two callers and both
  required a live, AUTHENTICATED connection — `activateSubscription` (reached
  from `auth_ok`) and `refreshSnapshot` (which needs a subscription that was
  already activated). So a socket that failed to connect meant the REST snapshot
  was **never even attempted**, on a device whose REST client had just answered
  a fleet list. A terminal `auth_failed` is the sharpest form (`supervise()`
  breaks out of its loop for the whole session); any transient failure inside
  the backoff produces the same silence for as long as it lasts, which is why
  the symptom is INTERMITTENT on a client who uses the app daily.
  The fix is a **GRACE-DELAYED FALLBACK** (`standaloneSnapshotGrace`, 2s), and
  the grace is what keeps the healthy path byte-identical: a socket that is
  going to work authenticates long before it elapses and
  `activateSubscription` **cancels** the pending fallback, so a healthy boot
  still makes exactly ONE `/snapshot` request from exactly the caller it always
  did, with CG-SM-4's ordering guarantee intact. The fallback carries `.standalone`
  scope, **not** the connection generation: a subscribe issued before the first
  `runConnection()` captures generation 0, which the connect then bumps to 1, so
  a generation-gated fetch would have its emit dropped as "superseded" in
  precisely the case it exists for.
- **2. MYR-326's HONEST END STATE COULD NOT BE RENDERED**, and this is the
  MYR-369 `VehicleRideShare.display` lesson repeating — **a pure rule with good
  tests and the wrong consumer.** `ColdSnapshotLoad` bounds the wait and
  publishes "Can't reach Lunar right now"; `ColdSnapshotLoadTests` proves it
  four ways at fleet level. `HomeScreen.body` then asked
  `selectedVehicle != nil && selectedTelemetry != nil && !isConnecting` and took
  the CONTENT branch — because `isConnecting` is correctly `false` once a
  `statusMessage` exists, and the fleet **LIST** had succeeded, so a vehicle row
  was present. The honest branch was reachable only when the LIST itself failed,
  which is the one case it was NOT written for. Home therefore went from a black
  skeleton to a full map + sheet drawn on a snapshot that does not exist —
  "Locating…", 0%, camera on the equator. **A name is not a position.**
  `OwnerHomePresentation.resolve` is that decision as ONE pure function over four
  facts, and its rule 1 is that a settled failure with NOTHING behind it outranks
  a vehicle row — gated on `hasLiveSnapshotForActiveVehicle` so a failure landing
  BEHIND real data still never blanks the sheet (NFR-3.12/3.13). A screen cannot
  forget an arm of an enum the way it can forget the third leg of an `if`/`else
  if`/`else`.
- **3. THE CAMERA WENT TO NULL ISLAND.** `VehicleContractMapping
  .placeholderActivity` parks a car at `(0, 0)` with the label "Locating…", the
  `.driving` arm's empty route resolves to `(0, 0)` too, and `recenter` wrote
  `centerOverride ?? vehiclePosition.coordinate` verbatim. **§2.3 makes `(0, 0)`
  the NO-FIX SENTINEL**, and `position(from:)`'s own doc comment already promised
  callers would never treat it as "a valid Gulf-of-Guinea location". The RIDER
  side kept that promise — MYR-336's `RiderVehicleProjection.hasFix` is the gate
  — and **the owner side never had the equivalent.** On a dark, muted, POI-free
  `.standard` style the Gulf of Guinea renders as a plain black rectangle, which
  is why the client read it as "nothing loading" rather than as a wrong place.
  `OwnerMapCamera` is the owner's gate: override → live fix → **cached
  last-known position** (widened ×4, because where the car WAS is not where it
  is) → `.unpositioned`, which writes NO region and leaves MapKit's own wide
  framing up. Deliberately **not** a fabricated default city — that is a lie with
  better lighting. The **vehicle MARKER is a separate question** and is withheld
  whenever there is no fix, even while the camera is positioned from cache: a
  camera is context, a gold pin is a claim that the car is there right now.
  `LastKnownVehiclePositionStore` is the cache (`AccountStorage`/
  `RecentDestinations` precedent — reverse-DNS key, `Codable`, `init(defaults:)`,
  30-day expiry, 12-entry cap) and it **refuses to store `(0, 0)`**, since
  poisoning the fallback from inside would be silent.

**The retry button is a DELIBERATE, CLIENT-DIRECTED DEVIATION** from MYR-326/
MYR-343's "a resume re-asks, no retry button". That recovery is real and still
runs — `LiveVehicleFleet.retry()` walks the SAME ladder `handleForeground` does,
in the same order, because a retry and a resume are the same request — but it is
invisible, and *"Nothing loading, what happened?"* is a question the screen has
to answer where it is asked. Only `.unavailable` carries it
(`OwnerHomePresentation.offersRetry`); **a skeleton must never grow one**,
because something is already running behind it.

Both scenes are live-path-only by construction (`SimulatedVehicleFleet
.statusMessage` is `nil`, its `isConnecting` is `false`, and the protocol default
`hasLiveSnapshotForActiveVehicle` is `true`, so every simulated input resolves
`.content`), and every fixture vehicle carries a real San Francisco coordinate,
so **every drift-gate capture is byte-identical**. `ownerColdReadFailed` is
`ownerConnecting` twenty-one seconds later — the same list row, no snapshot, the
budget spent — and `ownerNoFixMap` is a snapshot that ARRIVED carrying the `(0,
0)` sentinel, seeding no cached position so the capture is the `.unpositioned`
arm. A DEBUG scene gets its own in-memory position store
(`TelemetryComposition.debugScopedLastKnownPositions`), the same reason
`RootView.recentDestinationsStore()` does: a position left behind by hand-driving
a live scene must not frame a later capture.

```sh
SIMCTL_CHILD_MRT_SCENE=ownerColdReadFailed xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=ownerNoFixMap xcrun simctl launch <udid> app.myrobotaxi.ios
```

**A pure test could not have caught defect 2**, which is why
`App/UITests/OwnerColdReadFailureUITests.swift` exists alongside
`OwnerColdLaunchHonestyTests`: the pure suite proves the RULE, and only a real
launch proves the rule is what the screen consults.

**THE OWNER'S RIDE IN PROGRESS DID NOT SURVIVE A FORCE-QUIT** (MYR-396, client
defect, build `202607311641`) — scene `ownerDispatchColdAdopted`. TestFlight,
Jul 31: *"When I close out the app the owner loses the UI of the current ride in
progress."* Force-quit mid-ride, relaunch, and owner Home renders as if no ride
exists — no dispatch card, no status line, no Picked-up / Dropped-off control.

- **THE CAUSE IS AN ABSENCE, AND IT IS A GAP IN THE CONTRACT, not a missing
  fetch.** `LiveRideRequestService.start()` made exactly two cold-launch reads:
  `adoptOpenRiderRide()` → `GET /api/ride-requests`, which §7.8 defines as *the
  authenticated RIDER's own requests* (`ListByRiderPage`, `rider_id = :sub`), and
  `refreshIncoming()` → `GET /api/ride-requests/incoming`, which is status
  **`requested` ONLY** — *"decided rows leave the feed by construction"*. So the
  ACCEPT is the very thing that removes the ride from the only owner-scoped list
  there is, and `?upcomingForVehicle=` cannot help either: it is `accepted` AND
  **strictly future**, i.e. precisely the reservations that are NOT live. **On
  this wire an owner cannot ask which ride they are driving.** The rider side has
  had cold-launch adoption since MYR-230 and gained MYR-377's gone-live arm; the
  owner side, split out by MYR-325, never had the equivalent — `ownerDispatch` is
  a projection of a pipeline that starts every process empty and was filled only
  by a live accept and the WS frames that followed it.
- **WHAT THE OWNER *CAN* ASK IS `GET /api/ride-requests/{id}`**, which is
  party-only and therefore theirs. All it needs is the id — a fact this device
  knew and threw away when the process died. `OwnerDispatchPointer` is that one
  string, persisted (`AccountStorage`/`RecentDestinations`/
  `LastKnownVehiclePosition` precedent: `Codable` DTO, reverse-DNS key,
  `init(defaults:)`, 30-day expiry), and `refreshOwnerDispatch()` is the read it
  enables — run inside `start()`, on every foreground, and after an owner push
  tap. **A pointer is not a ride**: it is a question, and the SERVER's answer
  decides every arm, so a stale, terminal or dormant pointer can never put a card
  on screen.
- **THE ORDER IS LOAD-BEARING**: the dispatch is adopted BEFORE the incoming
  feed, so a live ride owns the owner's slot and the still-`requested` requests
  queue behind it — the arrangement those same two reads produce when they happen
  live. The displacement guard is the SAME `canAdoptIncoming` every other
  adoption site uses, so this cannot become a back door around "a live dispatch
  is never displaced", and a redundant foreground adopt over the ride already
  held makes **no request at all**.
- **DORMANCY IS THE SHARED PREDICATE** (MYR-376), not a second copy of the rule.
  A reservation accepted for tomorrow is `accepted` today, so an adoption keyed
  on status alone would put "En route to pickup" and a live "Picked up" over a
  parked car — that issue's defect, re-entered by a new door.
  `RideReservation.isAdoptableLiveRide` is consulted verbatim. **The pointer
  SURVIVES a dormant answer**, because dormancy is time-bounded: the same
  reservation is a live ride at its due moment. That answer also feeds
  `ownerDueReservation` into the ONE due-timer both pipelines share — the owner
  half of MYR-377's `riderDueReservation`, which could not exist before, since a
  relaunch left the owner pipeline empty and there was nothing to arm from. The
  wake goes through `refreshOwnerDispatch`, **not** `applyRemote`:
  `integrateOwner` has no arm for a non-pending ride the pipeline does not hold
  (it reads that as a queued row resolving elsewhere), so a plain refetch would
  fetch the record and drop it. Terminal (`completed`/`declined`/`cancelled`) forgets it — a
  re-adopted `completed` ride would also raise MYR-292's "Dropped off ✓" banner
  on every launch forever, since that acknowledgement is deliberately
  session-scoped. A `pending` ride is left to the feed, and **a read that FAILS
  adopts nothing and forgets nothing** (MYR-326's "loading ≠ unavailable",
  pointed at a pointer).
- **THE OWNER SLOT HAS ONE WRITE PATH NOW**, and that is what makes the pointer
  reliable rather than diligent. Every assignment to `ownerRequest` goes through
  `setOwnerRequest(_:serverID:)`, which derives the pointer from the slot's own
  status — MYR-389's lesson (*exit-side cleanup is only ever as complete as the
  exit list was on the day it was written*) applied before it could bite. An
  EMPTY slot clears NOTHING, deliberately: the pointer's whole job is to outlive
  a process that has no slot at all, so clearing is a statement about the RIDE,
  made only where one is known to be over. It is released on **sign-out** with
  the profile and the view mode.
- **Self-rides keep working on both pipelines** (MYR-325's same-account duality):
  the rider half comes back through MYR-230's list adoption and the owner half
  through this one, legitimately holding the same id.
- The scene is **live-path-only by construction** — the simulated service holds
  one in-process record and has no server to re-read, so both new seam methods
  are protocol no-ops there and every simulated owner capture is byte-identical.
  `ownerDispatchColdAdopted` composes the PRODUCTION `LiveRideRequestService`
  over a scripted `DebugRideRequestEndpoint` and lets the real `start()` sequence
  run. **The wire is what makes it proof**: the ride is served ONLY by
  `rideRequest(id:)` (`DebugRideRequestEndpoint.dispatched`, a third array on
  purpose) with an empty rider list and an empty incoming feed, so a stub that
  also listed it would let the scene pass with the adoption deleted. Its pair is
  `ownerDispatched` — the same leg-1 card reached by a live accept — so the two
  differ by provenance and by one name ("Mira" off `requesterName` vs the
  simulated "Sam"; the scene joins `rendersLiveIncomingRequest` so the restored
  record is narrated by the wire rather than the fixture persona).
- **The pure suite proves the RULE; only a launch proves the screen consults it**
  — `OwnerDispatchColdLaunchUITests` beside `OwnerDispatchColdLaunchTests`, the
  MYR-387 pattern, and it matters here because `ownerDispatch` reaches the screen
  through `HomeScreen.dispatchedRide`, which layers
  `OwnerRideStatusLine.dispatchCardVisible` and the `OwnerHomeState`
  acknowledgement on top of it.
- **Known and NOT closed here**: a ride accepted on ANOTHER device is not
  restorable by this client at all — there is no owner-scoped read that returns
  it, and a pointer only remembers what this device did. The honest fix is
  server-side (an owner "active rides" slice of the §7.8 feed, the shape
  `?upcomingForVehicle=` already set); until then a second device learns about
  the ride from its next `ride_status_changed` frame — and `integrateOwner`'s
  `else` arm DROPS that frame, because it has no case for a live ride the
  pipeline does not hold. Both halves of that are one server-side read away and
  neither is reachable from this client today.

```sh
SIMCTL_CHILD_MRT_SCENE=ownerDispatchColdAdopted xcrun simctl launch <udid> app.myrobotaxi.ios
```

Booking/pending/tracking scenes are seeded WITHOUT arming any timers, so they hold still for a screenshot instead of auto-advancing.

**Owner sheet peek band** (MYR-315 → MYR-345) — the peek band is the prototype's 210/280 **plus** the room each LIVE-ONLY qualifier line the hero actually renders costs: `MRTHomePeekQualifier.freshnessStamp` (25) and `.serviceCompletion` (16). The prototype's hero has neither line, so appending them to a fixed band spent the clearance `BottomSheet` reserves above the floating nav (`components.jsx:542` `padding: '6px 24px 100px'`; the nav's own top edge is 86pt from the physical edge) — the client's "the stamp crowds the menu". Simulated scenes render zero such lines, so they land on 210/280 exactly and stay byte-identical; the in-service and freshness scenes sit 16–41pt taller by design (and their map `bottomContentInset` follows).

**The reserve is PER LINE and equals what the line measures** (MYR-345, the client again on the day-old band: *"Weird gap between menu and synced just now… I just want a clean looking gap that's not large but also enough room"*). MYR-315 reserved a flat 24 for whichever line it was. The stamp genuinely costs 25 and the completion line ~16⅓ (a 12pt line box grouped under the header at 2pt, MYR-319) — so an in-service car over-reserved by ~8pt. **Because the hero is top-aligned, an over-reserve does not pad anything: every surplus point lands in the ONE gap between the hero's last line and the floating nav.** His screenshot measures 49.7pt of ink clearance where the same hero with no qualifier line shows 43.0. The rule now is that a live-only line brings exactly its own room, so the clearance is the prototype's in every variant — which also means the two heroes keep their OWN different gaps (parked 43.0, driving 37.3 measured ink-to-nav): 210/280 are the prototype's numbers for two different blocks of content and are not ours to equalize. **Tune the reserve against INK, not the layout box**: the gap the owner sees is measured from the last visible pixel, and the stamp's glyphs sit ~2pt lower in their line box than the 12pt location line they take over from — so the stamp reserves 25 against a 23⅓pt layout cost. Full-frame ink clearance, parked hero: 43.0 with no qualifier line, 43.0 with the stamp, 42.7 with both. `OwnerPeekBandTests` measures the REAL `ParkedSummary`/`DrivingSummary` through a `UIHostingController` across every variant (parked/driving × stamp × service line × charging) to ±2pt — the structural guard that no line may quietly eat the band — and the captures carry the sharp numbers.

**A `contentShape` inset is not a tap target** (MYR-345) — the stamp grew its hit area with `contentShape(Rectangle().inset(by: -15))` around a 13⅓pt row, delivering 43⅓pt: under the 44pt hard rule, and invisible to any test that asserted the INSET. The inset is 16 now, and `OwnerFreshnessStampUITests` asserts on the frame the system reports (which IS the grown region) and taps below the ink to prove it is live. Measured on iPhone 17 Pro: 45.3pt tall, bottom edge 109.3pt from the physical edge — 23.3pt clear of the nav.

**Owner sheet TALL detent** (MYR-332) — the owner sheet drags peek → half →
**tall**, where tall is the physical screen less `MRTMetrics
.sheetTallTopClearance` (140 = the prototype's 852 canvas less
`SHEET_HEIGHTS.search` 712, ride-request.jsx:47 — the sheet grammar's own tallest
surface, and enough to keep the `MapHeader` switcher showing). It is OPT-IN per
sheet (`MRTDetentSheet(allowsTallDetent:)`); every other sheet keeps its
peek↔half pair. Peek and half are byte-identical: their heights are unchanged,
the crossfade still completes at HALF (`PanSheet(progressUpperDetentIndex:)` —
without it the ramp would stretch to tall and leave half half-faded), and the
dense layer's scroll content keeps a `tall − half` bottom reserve below tall so
scrolling to the end lands exactly where it did before. Capture it with
`MRT_OWNER_DETENT=tall`.

**The map's camera inset is CAPPED at half** (MYR-338) — MYR-332 originally let
the map's `bottomContentInset` follow the sheet to tall, so MapKit's legal
attribution wouldn't be stranded behind it. But that inset is not only the
attribution's: it is what MapKit fits the written `.region` into
(`.safeAreaPadding(.bottom:)`), and at tall the unobstructed band is ~200pt, so
the camera RE-FRAMED and the vehicle pin + its callout ended up crammed behind
the `MapHeader` chip — the client's *"The map moves up with the bottom sheet.
Map should stay fixed."* `HomeScreen.vehicleMapBottomInset` now resolves for
`cameraDetent(for:)`, which caps everything above half AT half: past half the
sheet simply COVERS the map (the Apple Maps model, and exactly what MYR-250
settled for the rider sheet's idle↔search jump). It takes NO sheet geometry any
more — `MRTDetentSheet.onResolvedHeights` and its preference key are deleted
with it, so a sheet height cannot reach the camera even in principle. The
attribution now sits behind the sheet at tall, which is the trade HALF has
always made. Evidence: the visible map strip is byte-identical across a real
half→tall drag (`OwnerSheetTallDetentUITests
.testDraggingPastHalfDoesNotMoveTheMap` — 0.0 changed on this branch, 0.42 on
the pre-fix build, which is how the test was proven to be a real guard), and the
moving-fix probe across that same drag logs ONE `WRITE recenter` (the `onAppear`
seating) and nothing after it.

**Charge bar motion** (MYR-333 → MYR-337) — a live charge session is the ONE
thing in this app that says "something is happening right now", and it says it
with MOTION on the hero battery bar (`BatteryBar(charge:)`; scenes
`ownerCharging` / `ownerChargeComplete`, the second of which is deliberately
STATIC — the session is over, so motion would be a lie). MYR-333 shipped that as
a whole-bar opacity breath and the client came straight back: *"Charging pulse
is really faint. It should pulse across smoothly."* **A whole-surface fade has
no direction, so there is nothing for the eye to track** — and composited over
the dark sheet its two extremes were rgb(45,134,67) ↔ rgb(47,182,81), two greens
that read as one. It is now a bright highlight TRAVELLING left→right across the
fill on the design's established 2.6s travelling-highlight period
(`mrt-text-shimmer`, the CTA border trace), built as a per-frame
`TimelineView(.animation)` gradient — **not** a masked band moved by `offset`,
because MYR-326's lesson is that a masked band can composite once and never
re-render, looking motionless in stills AND in reality. Reduce Motion → static
green (proven: 1 distinct bar rendering across 6 lossless screenshots, vs 6 of 6
with motion on). **Prove charge motion by FRAME-DIFFING**, never by a still —
extract frames from a screen recording and show the highlight's peak advancing
0→1 over 2.6s. `simctl ui <udid> reduce_motion` does NOT take on this runtime:
use `simctl spawn <udid> defaults write com.apple.Accessibility
ReduceMotionEnabled -bool true` and relaunch. `MiniBattery` and the primitives
showcase are on the prototype's own amber `charging:` axis and are untouched by
all of this.

**Owner intent is not vehicle state** (MYR-342) — the ride-sharing pause
(`rideShareEnabled`, contracts 0.20.0; `PUT /api/tesla/vehicles/{id}/ride-share`,
rest-api.md §7.18) is the first availability fact in this app that the CAR does
not report. `in_service`, `offline` and `hasActiveRide` are things the vehicle or
the ride system says about itself, and **every one of them ENDS on its own**. A
pause ends only when the owner reaches for the switch again, and three client
rules fall out of that difference:

- **It is checked FIRST** in `LiveFleetMemberMapping.unavailability`. A car can be
  paused *and* in service; which reason we name decides which CTA the rider gets,
  and they disagree.
- **It offers no "Schedule instead"** — the one deviation from MYR-233's
  never-a-dead-end rule. The server refuses scheduled rides against a paused car
  on all three enforcement layers (create, accept, reservation sweeper), a
  deliberate deviation from the reservation exemption MYR-313 grants the others.
  A scheduling button would not be an escape from the dead end, it would be a
  longer walk to the same `409` — after the rider had picked a day, a time and a
  passenger. So `FleetUnavailability.offersScheduling` / `.exemptWhenScheduled`
  are per-case, and `RideRequestCTAGate.allowsSubmit` now derives from `isGated`,
  NOT from `routesToScheduling`: those were the same predicate until a reason
  existed that gates without offering scheduling.
- **It survives the own-ride exception**, which suppresses `busy` only.

**ABSENT MEANS ENABLED**, and this is the rule most likely to be broken by a
tidy-looking refactor. The field is optional on the wire; the contract says
absence "MUST be read as ENABLED" and consumers "MUST NOT fail closed on a
missing key". So every predicate tests `== false` **explicitly** —
`VehicleRideShare.isPaused` is the one place it is spelled. `!= true` is the
natural spelling and would withdraw every car served by a pre-0.20.0 server at
once. Note this points the OPPOSITE way from `VehicleServiceWindow`'s nil rule,
which is why both are written out rather than assumed.

**The merger does NOT fold it, and that is a security property rather than
housekeeping.** The Mirror tripwire forces fold-or-declare and this one is
DECLARED (`snapshotOnlyFields`), because §7.18 keeps the column off the shared
telemetry-fed control-state upsert specifically so no routine frame from the car
can re-enable ride sharing on a vehicle its owner paused — asserted upstream by
`TestVehicleRepo_RideShareIsNotReachableFromTelemetry`. A merger arm would hand
that path straight back on the client. The pause is liftable by exactly one
actor. (It looks foldable — a plain optional `Bool`, the shape of every folded
cabin field — which is exactly why the reason is written out.)

**The write is optimistic AND rolls back.** `LiveVehicleCommandExecutor
.setRideShareEnabled` flips the row immediately (a toggle that waits for a round
trip reads as broken), adopts the server's ECHO rather than the bool it sent, and
on failure restores **both** the value and the MYR-251 known flag before settling
`.rideShareNotSaved`. Leaving the optimistic position up would manufacture the
exact belief §7.18 refuses to allow — an owner walking away thinking their car is
paused while it is still taking requests. Like the plate and the service window
it has NO WebSocket delta, so `VehicleRideShare.resolvedEnabled` prefers the
committed value over the snapshot (the MYR-316 stale-read defect, avoided in
advance) and `LiveVehicleFleet.onRideShareSaved` pushes the echo into the summary
row the rider-facing mapping reads.

**A wrong key on an optional decodes to `nil`, and nothing anywhere says so**
(MYR-362) — TestFlight, build `202607300926` (the build carrying MYR-351's fix):
*"Just set the time and it didn't stick or update on the sheet."* His screenshot
is the owner sheet on an in-service car with "Service completion date / **Set a
time**" EMPTY, seconds after saving one.

`PUT /service-window` answers `{"vehicleId":…,"expectedEndAt":…}`. The Kit's
hand-authored `VehicleServiceWindowResponse` declared **`serviceEstimatedEndAt`**
— a key §7.16 has never emitted. Every property on it is optional, so the body
DECODED, cleanly, to `nil`. `setServiceWindow` then took the success branch in
full: committed the nil, raised MYR-251's known flag, stamped MYR-351's commit
instant, settled `.idle` with **no notice**, and broadcast the nil into the
summary row the RIDER's scheduling floor is built from. There was no throw, no
4xx, no log — every signal the app had said the save worked.

- **It is a SET and never a CLEAR.** A clear WANTS nil and the mis-decode
  produced nil unconditionally, so it was right for the wrong reason. Every
  service-window test MYR-316 and MYR-351 wrote drove `setServiceWindow(nil)`,
  which is how a defect on the other half of the same method survived two rounds
  of tests about this exact field. **When a method's success value can be `nil`
  legitimately, the nil case is not coverage of the non-nil case — it is camouflage
  for it.**
- **MYR-351 did not cause it; it removed the recovery.** Before #130 the next
  telemetry frame re-played the last snapshot's snapshot-only fields, so the row
  repopulated itself within seconds (and on a car whose snapshot already held a
  window, invisibly — that re-play IS MYR-351's report 1, "it popped right back").
  `committedAt` now correctly refuses every read ISSUED before the write, so the
  mis-decoded nil is preserved exactly as a real committed value would be. **The
  guard is right; what it was faithfully preserving was never the server's
  answer.** A correct fix that removes a bug's accidental self-healing will
  surface every latent defect underneath it.
- **The stub and the fixture agreed with the fiction, so the suite was green
  about a body the server never sends.** `DebugServiceWindowEndpoint` returned the
  invented key and `vehicle_service_window.json` carried it, both hand-authored
  from a misreading of §7.16. `ownerServiceWindowSaved` therefore rendered the
  time correctly on the broken build — **the scene could not have caught this, and
  no screenshot ever could.** A hand-authored fixture is evidence only to the
  extent it is the wire; the guard that works is asserting on the RAW fixture keys
  (`testTheResponseFixtureCarriesTheOwnerColumnKeyAndNotTheResolvedOne`) plus a
  decode test over §7.16's own printed example, because a wrong key on an optional
  can never fail a decode.
- **§7.16 echoes the OWNER COLUMN on purpose**, and MYR-316 read it backwards.
  The spec's words: "echoing the resolved value would make a client believe its
  write had been overruled when it has merely been outranked by Tesla on the next
  read, and would leave it with no way to display the value the owner just typed."
  The resolved window is `COALESCE(service_etc, service_expected_end_at)` and is
  knowable ONLY from §7.0 / §7.1. The contract names the two legal client
  responses — "adopts this response optimistically or re-reads" — and
  `setServiceWindow` now does both: it adopts the echo, and MYR-351's deliberately
  non-latching guard gives the first read issued after the commit the last word.
- **The provenance moved to where it is provable.** MYR-320 classified `.manual`
  vs `.tesla` by comparing the write echo to the submission — but the echo IS the
  submission by construction, so that comparison answers `.manual` every time,
  asserting "Tesla hasn't provided an estimate for this visit" about a car whose
  estimate was never read. The same `provenance` classifier is now fed from the
  first read ISSUED after the commit (`pendingServiceWindowProvenance`, consumed
  once), where equal-to-what-we-stored genuinely proves Tesla had no `service_etc`
  to outrank it. That makes MYR-320's caption **correct and reachable in
  production for the first time**.

**Quick-tile captions** (MYR-335) — the four `ControlTile`s split the sheet's
content width, so each holds ~50pt of text on the narrowest supported device
(375pt). Every caption is measured against that in
`VehicleControlTileCaptionTests`; nothing may rely on the prototype's ellipsis
fallback. This cost a deliberate deviation from the jsx's own copy, which does
not fit its own tile ("Tap to unlock" ellipsizes in the running prototype too):
the lock sub is the verb alone ("Unlock"/"Lock", the state is the label), the
charge sub is the door state alone ("Open"/"Closed", "Port" is the label's job),
and the per-tile "X ago" recency is gone — recency is stated once, by the
MYR-315 freshness stamp in the hero, plus the "Not live" footer.

**A blend mode over MapKit is not a blend mode** (MYR-339) — the 100%-FSD Drive
Summary flooded the hero map with gold on the client's phone while his
screenshots looked right: *"When I screenshot the page looks normal with the gold
for 100% FSD, but on the actual app on my phone it's gold even overlaying the
map."* The tint was the prototype's own `mix-blend-mode: soft-light` over gold at
α 0.5→0.85 (screens.jsx:885), ported verbatim. **In CSS that alpha is safe
because the blend is isolated**: the tint's parent (screens.jsx:873, `position:
relative; z-index: 1; overflow: hidden`) creates a stacking context, so soft-light
resolves against ordinary painted DOM. In SwiftUI the same layer sat in a plain
`ZStack` directly above a `Map` — a UIKit-hosted `MKMapView` on its own
compositing surface — where a blend mode resolves against whatever backdrop the
compositor has, and with none it paints **source-over**: gold at 0.5→0.85, flat
across the map. Measured over the real hero pixels: un-tinted RGB(27,37,53)
lum 0.143 → soft-light RGB(44,48,43) lum 0.184 (contrast 0.11 preserved) →
blend dropped RGB(145,127,70) lum 0.496 (contrast 0.060, **45% of the map's
readability gone**). **A screenshot cannot catch this**: a still is taken by
flattening the whole layer tree into ONE offscreen buffer, a pass in which the
backdrop IS available and the blend DOES resolve — which is why the client had to
photograph the phone, and why the simulator can't reproduce it either (both its
framebuffer and `XCUIScreen.screenshot()` render soft-light correctly, matching
the prediction to rmse 0.0225). MYR-339 fixed that by pre-resolving the tint to
normal compositing at 0.07→0.09. The rule generalizes and OUTLIVES the layer:
**never let a blend mode, or any effect needing a backdrop read, be what stands
between the user and a hosted `MKMapView`** — resolve it to normal compositing
and put the number in a token a test can assert on
(`MRTDriveCelebration.celebrationBlendMode` must stay `.normal`).

The capture route was its own trap: `MRT_SCENE=ownerDrives
MRT_OPEN_FIRST_DRIVE=1` opens `DriveFixtures.drives[0]` — **97% FSD**, so
`celebrates` is false and not one celebration branch is ever constructed. The
celebration has no cold-scene route at all; the 100% drive is the SECOND row.
`App/UITests/DriveSummaryCelebrationUITests.swift` reaches it by real taps on the
real navigation path and emits the drift-gate captures — the same
`ExpandedRouteUITests` precedent, and a live instance of the repo's own "cold
scenes passing while real paths fail" lesson.

**The celebration is a MOMENT in the ELEMENTS, not a wash** (MYR-346 —
**a DELIBERATE, CLIENT-DIRECTED DEVIATION FROM THE PROTOTYPE**). On the FIXED
MYR-339 build the client rejected the treatment itself, twice: *"I know we fixed
this and the prototype looks like this but it literally looks like someone puked
on the screen and it's hard to read. I still want a special look to the page with
100% FSD but something cleaner with the gold. Try something cleaner, crisper, and
more rewarding."* **Client outranks prototype** (standing precedent), so
screens.jsx:852-886's page wash + hero tint + hero highlight and
screens.jsx:1030-1136's pop / glow halo / ring flash / 34-particle confetti burst
are **all deleted** — the prototype's own celebration is not ported at all. This
is also the strongest form of the MYR-339 fix: the layer whose compositing was
the defect no longer exists, so it cannot regress in any compositing environment.

On a 100% drive the map, the page ground, the header and every non-FSD tile are
now **byte-identical to a 97% drive's** (measured: the whole page below the hero
diffs bbox=None, maxdelta=0 base vs branch). What is left is concentrated in the
FSD stat block and shaped as an ENTRY MOMENT, `MRTDriveCelebration
.momentDuration` = **1.72s**, then perfectly static:

- **The ring is the hero.** It draws itself on the 97% ring's OWN schedule
  (0.12s delay + 1.15s `cubic-bezier(0.32,0.72,0,1)`) behind a bright
  `goldTraceBright` head — `RouteEtchTrace`'s three layers verbatim (wide bloom →
  tight glow → hot core), i.e. the ride-CTA outline-draw / route-etch grammar at
  ring scale — and the head **glints once at 12 o'clock** as it lands (0.45s
  easeOut, scaling 1→1.6 as it fades, so the moment ends on a brightening).
- **It settles slightly richer than the 97% ring**: the same gold as an angular
  gradient with a `goldLight` highlight at 12 o'clock where the glint landed,
  plus a faint static `mrtGoldGlowFaint` halo. **Every stop is `gold` or
  LIGHTER** — asserted, because half the client's complaint was readability and
  "richer" may never mean "dimmer than the 97% ring".
- **The "100%" numeral + "FULL SELF-DRIVING" kicker** take a permanent
  `goldLight → gold → goldDeep` struck-metal gradient — but the `goldDeep` stop
  is held to the bottom 30% so the gradient's MEAN luminance still lands above
  flat gold's (also asserted). Permanent, and local to the stat block.
- **One fine gold hairline** on the FSD tile (`mrtGoldBorderQuiet`, gold @0.18)
  replaces its neutral border. Fill, radius and padding untouched.
- **Reduce Motion boots straight to the settled state** — no draw, no glint.

Nothing animates after 1.72s, which is the whole point: the old wash arrived at
t=2.7s and then simply stayed. **Prove this pair by FRAME SEQUENCE, never by a
still** — `DriveSummaryCelebrationUITests` captures back-to-back
`XCUIScreen.screenshot()`s (~75ms apart, no sleep) across the entry and names each
with its wall-clock offset, so the sequence reads against the numbers above.
Verdicts that must hold: **~22 distinct ring renderings of 32 frames** with motion
on, **every frame from t≥1.8s identical**, and under Reduce Motion **1 distinct
ring rendering across all 33 frames, byte-identical to the motion-on settled
ring**.
(`simctl ui reduce_motion` does not take on this runtime — use `simctl spawn
<udid> defaults write com.apple.Accessibility ReduceMotionEnabled -bool true`.)
The `mrtConfettiPale` token went with the burst; every other colour it used was
already a shared gold.

**The rider's "N min away" is ONE estimate** (MYR-341) — the idle sheet's
rotating placeholder ("A ride is N min away", screens.jsx:1977-1980), Review's
pickup sub, and Booking's pickup clock are all `RiderPickupETA`: the existing
`TripEstimate` closed form (great-circle × 1.3 ÷ 24 mph, ≥1 min) from the watched
vehicle's coordinate to the rider's. **Deliberately NOT MKDirections** — the
placeholder is visible the whole time the rider sits on idle and re-renders on a
2800ms rotation, which is precisely the visible-cadence re-ask Apple's throttle
punished in MYR-237. Two stability guards, because a device streams fixes at ~1Hz
and this number sits under a crossfade: endpoints are **quantized to a ~250m
grid**, and a `StableFixAnchor` **latches** the anchor until a fix lands a full
cell away (quantization alone does not survive a fix jittering across a grid
BOUNDARY). The anchors are re-seated on idle-sheet appearance and on raw-endpoint
change, and only WRITE when the move was material, so a streaming fix invalidates
nothing.

Four honesty gates, all in `RiderIdlePlaceholder.items`, any of which returns the
plain `["Where to?"]` a single-item `RotatingPlaceholder` never rotates: **no
device fix**, **no vehicle coordinate**, an **unavailable car** (the MYR-233
`FleetUnavailability` predicate reused verbatim — a car in a service bay has a
perfectly computable straight-line distance and is still not "N min away"), and
**a request already in flight** (the prototype's own `reqActive`,
screens.jsx:1964). The first gate has a trap worth naming: the rider endpoint
must come from the LOCATION SEAM and never from `SharedViewerState
.mapRegionCenter`, whose fallback ladder resolves to the VEHICLE's own coordinate
— an implementation that reached for it would estimate the car's distance to
itself and tell a rider with no location permission "A ride is 1 min away".

`LiveFleetMemberMapping.etaMin` used to copy `RideRequestFixtures.fleet[0].etaMin`
— a fixture 3 asserted about a car nobody had measured, and a MYR-228 leak with
no grep signature. It now emits the **0 sentinel**; `SharedViewerState
.liveFleetMember` (the same single seam that folds the own-ride exception) fills
it, following `TripEstimate.applied(to:)`'s gate style exactly — fill only when
the value is 0, so no fixture is ever overwritten. That makes 0 genuinely
reachable on live, so `RidePickupETADisplay` renders it as a calm unknown ("—",
and no "N min away" note) rather than "0 min away" / "arriving now".

**This element cannot be drift-gated by a screenshot.** The placeholder's trace
border, search glow and rotation crossfade animate continuously and its clocks are
wall-clock-derived, so two launches of the SAME binary diff (measured: a
base-vs-base control diffs as much as base-vs-branch). The gate is asserted
instead — `RiderIdlePlaceholder.items(resolvesLiveETA: false, …)` returns the
prototype's fixture pair before any live machinery is consulted, pinned in
`RiderPickupETATests`. What images CAN prove was proven: the settled glyph masks
of both placeholder strings are byte-identical across base and branch, and
Review's stat pair + Booking's whole itinerary band are pixel-identical.

**The idle sheet says WHY the ETA went quiet** (MYR-352) — TestFlight, Jul 30:
*"If no owner vehicles available with ride share enabled we need to display a
banner saying no rides available right now. Kind of like the Tesla Robotaxi app.
We can do it as a sleek banner above the search bar."* MYR-341 already SUPPRESSES
"A ride is N min away" whenever the car is unavailable, on the honest reasoning
that a car in a service bay is not N minutes away at any distance. Correct — and
silent: the rider was left with a bare "Where to?" over a fleet that cannot take
one request, and the first thing that said otherwise was a Review sheet two taps
later. The banner is the WHY the placeholder deliberately does not say, and both
are raised by the SAME `FleetUnavailability` non-nil, so the bar and the banner
can never contradict each other (asserted across all four reasons).

- **The predicate is over the SET, not the watched car.** `banner(members:)` is
  `nil` unless the set is non-empty AND *no* member is requestable — one free car
  cancels it outright, whatever the others are doing. Empty is `nil` too: "no
  rides available" about NO vehicles is MYR-343's `.empty` shell answering a
  different question.
- **`RiderLiveVehicleLocator` now publishes the WHOLE `GET /api/vehicles` list**
  (`fleetMembers`), not just `.first`. Same fetch, same endpoint, no new call —
  MYR-212 discarded the tail only because the ride is created against the head.
  `fleetMember` is `fleetMembers.first`, so every requesting/tracking/naming
  surface is untouched, and this is **not** the multi-vehicle picker (still
  MYR-91). `SharedViewerState.liveFleetMembers` puts the fully-resolved
  `liveFleetMember` at the head so the own-ride exception and the pickup-ETA fill
  still live in exactly one place.
- **Copy**: one vehicle → `"{name} {clause} — no rides right now"`; more than one
  → the client's generic `"No rides available right now"`, because with two cars
  out for two reasons no single reason is true of the fleet. Two cars sharing a
  reason is deliberately NOT special-cased — that is a coincidence, and specific
  copy would assert it as a pattern. Second line `"You can still schedule a
  pickup."` only when some unavailable member `offersScheduling`, i.e. MYR-313
  for `inService`/`offline`/`busy` and **never** for `paused` (§7.18 refuses
  reservations there on all three layers).
- **`FleetUnavailability.riderClause`** is the shared verb clause ("is in
  service" / "has paused ride requests"). MYR-233's four Review helper literals
  are now composed from it — byte-identically, pinned — so the banner and the
  helper line cannot drift, and `paused`'s differently-shaped sentence lives in
  one place.
- **The banner brings exactly its own room, and it has to be MEASURED to know how
  much.** The idle card was a fixed 286 (`sharedIdleSheetHeight`) sized for
  greeting + search bar + chips ≈ 259; the banner is the first element that can
  exceed that band, because its headline wraps to two lines for the longer
  reasons **even at 393pt**. Dropped into the flat frame it pushed the Home/Work
  chips under the floating nav. So the card's height is `286 + measured banner +
  riderIdleBannerGap (14)`, and the same value feeds the engine's idle detent and
  MapKit's attribution inset (MYR-223's rule unchanged) — one number, three
  consumers, so the card, the sheet and the map's clear band cannot disagree.
  This is MYR-345's per-line-reserve rule where the room is only knowable by
  asking the line.
- **TWO traps, both cost a round.** (1) **Measuring the CARD is a layout loop** —
  it ends in a greedy `Spacer(minLength: 0)`, so it reports back whatever the
  engine proposed, the detent adopts it, and the pair ratchets upward every pass
  (the sheet ran away and the screen went black). The BANNER is the only thing
  here safe to measure: its height is a pure function of its copy and the width,
  with no edge back to the sheet's size. (2) **`minHeight` is not a substitute for
  a fixed frame** — a floor lets the same greedy `Spacer` absorb the proposal,
  which stretched the sheet's gradient wash and drifted `riderWatchOnly` (a
  byte-stable scene) by ~913k pixels at max delta 13. The frame stays FIXED and
  the reserve is added to the number.

**A GATE WHOSE INPUT ONLY A COLD LAUNCH CAN CORRECT IS A LATCH** (MYR-402, client
defect, build `202607311641`) — his active ride was cancelled SERVER-SIDE and the
idle sheet's "A ride is N min away" never came back. His rule, verbatim: *"if you
had a ride in progress and then no longer in progress the app should not have to be
forced closed for the ride is x min away to show up."*

MYR-341's four honesty gates were all CORRECT. Two of their INPUTS could be
corrected by nothing short of a relaunch, which is the whole defect and is the
MYR-389 "works after a force-quit" signature for the third time.

- **THE ONE THAT FIRES ON THE HAPPY PATH is the availability gate, and it CLOSES on
  the transition that should OPEN it.** `FleetUnavailability` comes from
  `VehicleSummary.hasActiveRide` on `GET /api/vehicles`, and
  `RiderLiveVehicleLocator` read that list **exactly once per rider-map mount** —
  `handleForeground` refreshed the SOCKET's snapshot and nothing refreshed the
  LIST. Worse, the staleness was INVISIBLE for the entire ride: MYR-233's own-ride
  exception suppresses `.busy` for the rider holding the ride, so the pre-ride row
  (`hasActiveRide: true`) sat masked and became load-bearing the instant the ride
  was erased. **The rider's own finished ride was then reported back to them as the
  car being busy** — no ETA line, and MYR-352's "no rides right now" banner over a
  free car. `syncRiderOwnsActiveRide`'s own comment had promised "a genuinely busy
  car reads Busy again **on the next list fetch**"; there was no next list fetch.
  **A masked stale value is worse than a visible one — every test and every
  screenshot taken DURING the ride is correct.**
- **THE SECOND is the rider's slot, and it was releasable by exactly one channel.**
  `refreshActiveRide()` was `adoptOpenRiderRide()` alone, whose first line is
  `guard activeRequest == nil` — **adopt-only**: it could fill an empty slot and
  could never empty a full one. So a cancellation (MYR-172's ERASURE: mapped to no
  status at all, the record simply disappears) reached the client only as a WS
  `ride_status_changed` frame, and a socket that was down, backgrounded or
  terminally `auth_failed` (MYR-387's own finding) left a cancelled ride in the slot
  for the rest of the session. `RootView` had gained MYR-396's foreground re-read
  for the OWNER pipeline and the rider pipeline still had none.
- **TWO CALLERS WERE ALREADY WRITTEN AS THOUGH THE RE-READ HAPPENED.** MYR-397's
  awaited cancel documents "the caller's `refreshActiveRide()` re-reads and
  `integrate` maps the wire's `cancelled` to the record disappearing", then settles
  on `RiderActiveRideCancel.stillStands(status: activeRequest?.status)` — reading
  back the LOCAL optimistic record, and right only because a frame usually followed.
  The push tap's comment says it "pokes the EXISTING refresh that repopulates" the
  rider surface. **A doc comment describing a call's effect is not evidence the call
  has it**, and both of these read as correct at their own call site.

The fix is three doors into one funnel, plus one that cannot be left half-open:

- `RiderLiveVehicleLocator.refreshFleet()` re-reads §7.0 (coalesced onto any load in
  flight, silent while the map is off screen, and a failed read changes nothing —
  MYR-326's rule). `SharedViewerState.refreshRideEndGateInputs()` is the ONE funnel
  over it plus the anchor re-seat, so an input added later joins in one place and is
  covered by all three events at once — MYR-389's entry-invariant lesson pointed at
  READS rather than at writes.
- `refreshActiveRide()` now re-reads the HELD ride before adopting, **through
  `integrate`** — the same fold `applyRemote` applies to a frame — so a refetched
  cancellation erases the slot by the identical code path and there is no second
  definition of "this ride is over". Narrow on purpose: a server id is required (an
  optimistic MYR-218 record has nothing to ask about), a record must be held (else
  a dismissed summary would be resurrected), and a failed read changes nothing.
- **`riderOwnsActiveRide` is `private(set)` and `setRiderOwnsActiveRide` is its only
  door.** The exception LIFTING is the moment the masked row becomes load-bearing,
  so the lift and the re-read are now one statement the compiler enforces rather
  than two call sites one of which can be forgotten. It fires on the true→false EDGE
  only — `syncRiderOwnsActiveRide` runs on every appearance and every status fold,
  and a refetch on each would be a poll wearing an observer's clothes.
- `RiderIdleGate` names the three gates and `RiderIdlePlaceholder.items` is DERIVED
  from `suppressingGate`, so a test can say WHICH gate latched. Before it, every
  failure mode produced the identical `["Where to?"]` and a test could prove that
  recovery failed without being able to say what failed to recover.

**THIS SURFACE STILL CANNOT BE DRIFT-GATED BY A SCREENSHOT** (MYR-341's own note —
the trace border, the search glow and the 2800ms crossfade make two launches of the
SAME binary diff), and MYR-402 adds that it cannot usefully be given a capture scene
either: the rider locator has no HTTP-injection seam, and reaching the gate through
`debugFleetMembersOverride` would bypass the very list read this issue is about — a
scene that passed for the wrong reason, which is the `VehicleRideShare.display`
lesson. The guard is `RiderIdleGateRecoveryTests`, which drives the REAL composition
(production locator over a `RoutedHTTP` whose `/vehicles` body CHANGES mid-test,
production `LiveRideRequestService` over a scripted API and a controllable stream)
and sweeps every `RiderIdleGate` for in-process recovery. **`RoutedHTTP.setBody`
exists for this**: every stub before it was a fixed script, which answers "what does
the client make of this payload" and cannot answer "does the client ever ASK AGAIN"
— a fixed stub makes a re-read indistinguishable from a cached value, so a test
built on one passes on the broken build.

**Never present over a live first responder** (MYR-353) — TestFlight, Jul 30:
*"When I tap on schedule it pops up behind the keyboard. Needs to be fixed."*
`RideSlideUpCard` is an in-hierarchy overlay, bottom-flush and
`ignoresSafeArea(edges: .bottom)` — which by design includes the KEYBOARD region —
so the card laid out against the physical screen edge and the keyboard window drew
straight over its day/time chips and its "Set pickup" CTA. Nothing the app
computed was wrong; the MYR-239/344 class exactly.

All THREE entry points now funnel through one `openScheduleCard()` carrying
MYR-344's `presentHandout` pattern verbatim — drop the `@FocusState` binding AND
force-resign via `MRTKeyboard.dismiss()`, then pay `dismissalSettle` (0.25s) **only
when a responder actually gave the keyboard up**, so a card opened with no keyboard
present is byte-identical to before. The three are the Schedule chip, the
"Pickup {day} · {time}" summary row's Edit, and Review's one-shot
`opensScheduleOnSearch` route. The first two matter most because
`scheduleSearchFocus()` **auto-focuses the destination field by design** 450ms
after the sheet settles — keyboard-up is the DEFAULT state the chip is tapped in,
not an edge case.

The same auto-focus is the hazard pointing the other way: `consumeScheduleRouting()`
opens the card from inside the very `onChange(of: sheetPhase)` that arms the focus,
so `scheduleSearchFocus` now also guards on `!scheduleSheetOpen` (evaluated after
its sleep) — a keyboard rising UNDER an open card is the same defect from the far
side. Audited and RULED OUT for the two other `RideSlideUpCard` consumers
(Review's fleet picker, Summary's tip quip) and for `ScheduledRideSheet`'s inline
reschedule: the rider flow's only text fields are the Search sheet's destination
and passenger name/phone, so no other card can be presented over a keyboard.

**A field with no declared content type is not neutral** (MYR-363a) — the
destination search field's QuickType bar offered iOS's **one-time-code** ("From
Messages") suggestion. The cause was an ABSENCE: grepped across `App/` and
`Packages/`, `textContentType` appeared **zero** times — not on the destination
field, not on the passenger name/phone pair, and **not on `InviteCodeFlow`'s hidden
six-character field either** (it declares only `.asciiCapable` +
`autocorrectionDisabled`, so nothing was inherited from it). Nothing was leaking;
the field simply never told iOS what it holds, and UIKit's heuristics classify an
unadorned single-line field as a plausible code target whenever a message carrying
one is in range. **The guess is worst exactly where the field is most generic.**
`RideRequestFieldContentType` names all three — `.fullStreetAddress` /
`.name` / `.telephoneNumber` — as constants rather than three modifiers buried in a
1200-line view, because a modifier is not assertable and a constant is
(`RideRequestFieldContentTypesTests` pins that none of them is `.oneTimeCode` and
none is empty). `.fullStreetAddress` over `.location`: the field's own subtitle line
is an ADDRESS, and `.location` offers place names only; `.none` would suppress the
code equally but also refuses the rider their own saved addresses and re-states the
"nothing in particular" that caused this. **On-sim evidence**: `searchFiltered`'s
QuickType row went from `"fer" | feral | fermentation` to empty — the app's own
pixels are byte-identical and only the keyboard process's suggestion bar changed.

**The segment caption and the idle banner answer different questions** (MYR-363b,
CLIENT-DIRECTED) — MYR-361 took `RiderIdleAvailabilityBanner`'s headline verbatim
for the caption under a disabled "Now", so a single-vehicle rider read their car's
own name under a dimmed chip. The SEGMENT caption is now the generic
`"No rides available right now"` in **every** case and the vehicle-named sentence
lives **only** on the idle banner. The PREDICATE is still the banner's own non-nil,
so the two can never contradict each other; only the copy parts, and both halves are
asserted together so neither can drift onto the other. The generic line is also the
one sentence that stays true under a LATCHED value as the set changes.

**A default with nothing to act on is half a fix** (MYR-363b) — MYR-361 moved the
selection to Schedule when nothing can take an instant request and stopped there, so
the rider picked a destination and got a "Continue" that walks to a Review whose CTA
is gated: MYR-233's dead end by a different road. `RideScheduleDefaultPrompt` opens
the schedule card ITSELF when the segment **DEFAULTED** (not when the rider chose
Schedule — that tap already opened it), no time is committed, the card is not already
up, and this draft has not had its shot. **ONE SHOT PER DRAFT**: the latch is set as
the card opens, so an explicit dismissal is final and a different destination does
not re-ask; it clears only with `resetDraftToIdle`. It presents through the shipping
`openScheduleCard()`, so MYR-353's keyboard rule and MYR-316's floor reconciliation
are the real ones — and this entry matters most for MYR-353, because it fires
immediately after a result tap with the keyboard genuinely still up.

**A rule the picker cannot see is indistinguishable from a bug** (MYR-385, contracts
**0.26.0**) — scene `riderScheduleBooked`. r15, build `202607311129`: *"Still letting
me schedule for noon even though I already have a ride scheduled for that time."*

MYR-383 shipped the SERVER gate in r14 and it **does** refuse that booking —
`409 vehicle_unavailable` / `subCode: time_conflict`, at SUBMIT, after the rider has
picked a day, picked a time and tapped a CTA naming both. Nothing was broken; the
refusal simply arrived after somebody had committed to a choice, which reads as a
defect. `GET /api/vehicles/{id}/booked-windows` (rest-api.md §7.22) is the READ side
of that same gate, and the picker now dims the slot instead.

**THE INVARIANT** is the server's: a slot the picker dims is exactly a slot the gate
would refuse, and a slot it leaves enabled is exactly one the gate would allow —
both are assembled from the same SQL fragments and reach the window constant through
the same bind parameter. Four client rules keep this side of it honest, and each is
a way it could have broken quietly:

- **THE ±45min HALF-WIDTH NEVER CROSSES THE WIRE, AND MUST NOT BE RE-DERIVED.** §7.22
  emits **concrete instants** rather than an anchor plus a radius, deliberately: the
  half-width is a PRODUCT GUESS living in one place on the server
  (`store.RideConflictWindow`), passed to SQL as a bind parameter and encoded in no
  schema, no enum and no client — so widening or narrowing it changes every picker on
  the **next response**, with no client release and no contract bump. Nothing in
  `RideBookedWindows.swift` adds, subtracts, re-centres, pads or rounds an instant,
  and `testNothingInThisLayerKnowsTheHalfWidth` walks a deliberately WRONG half-width
  (±3h and ±10min) to prove the dimming follows the emitted endpoints. The only place
  in this repo that knows 45 minutes is `DebugBookedWindowsEndpoint`, a DEBUG stub
  standing in for the server that owns the number.
- **THE INTERVAL IS OPEN AT BOTH ENDS.** The gate compares strictly inside, so a
  reservation at exactly `start` or exactly `end` is ACCEPTED — two rides that touch
  at a boundary are a legal back-to-back booking. `contains` is `start < slot && slot
  < end`; `<=` is the spelling a hand reaches for and it refuses slots the server
  would have taken. On the shipped 30-minute grid a noon window takes exactly three
  chips (11:30 / 12:00 / 12:30), which is what the test asserts.
- **`items: []` MEANS "NO RESERVATIONS", NOT "WIDE OPEN".** §7.22 deliberately does
  not consult the §7.18 ride-share pause or the §7.16 service window — both refuse a
  create, neither describes a window — so a paused or in-service car answers with its
  real, usually empty, list. Reading empty as "free" would undo two other gates.
- **A WINDOW IS A SNAPSHOT, so the 409 stays the AUTHORITY.** Windows vanish (the
  holder cancels — a refusal is a DEFERRAL, never a permanent hold on a slot) and the
  ACTIVE-INSTANT arm anchors on the server's clock, so it SLIDES forward while the
  response does not. This reduces how often a rider meets the refusal; it does not
  replace it.

**ONE GRID PREDICATE, NOT A PARALLEL SET.** The windows are threaded through
`RideScheduleFloor`'s existing `allows` / `allowedTimes` / `allowedDays` /
`firstAllowedSlot` (a `windows:` parameter defaulting to `[]`, so every pre-MYR-385
caller and test is unchanged by construction) rather than given their own helpers.
Five call sites in the card — day chips, time chips, the CTA gate, the reconciler and
its fallback scan — would otherwise each have had to remember to consult both, and
the first one to forget produces a chip the CTA refuses or a "first bookable slot"
that is not bookable. The two rules are also **different in kind and neither may be
expressed as the other**: the service floor is a monotone bound, windows are
scattered intervals with bookable gaps, so folding windows into a "floor" would push
the earliest slot past a perfectly free morning. A day chip stays lit while ANY of
its times is free, which matters far more for scattered windows than it did for a
floor.

**FAIL OPEN, WITH NO BRANCH SAYING SO.** `RideBookedWindowsStore` has deliberately
**no `isLoading`, no error state and no retry**: a spinner would gate the flow on an
advisory read, and MYR-326's "honest end state" rule does not apply either — "we
could not check" is not something a rider can act on. A failed read publishes nothing
**and records no coverage** (adopting an empty result would say "checked, all clear"
about a range nobody checked), an unparseable instant is dropped rather than guessed
at, and `windows(for:)` answers `[]` for any vehicle but the covered one — so a draft
re-pointed at another car can never be dimmed by the first car's calendar. Every
degradation lands on "the picker behaves exactly as it did before MYR-385".

**THE LIVE GATE IS AN ABSENCE, NOT AN `isLive` BRANCH.**
`PlaceSearchComposition.Seams.bookedWindows` is `nil` in sim, and the store refuses to
construct a read without a provider — so a simulated picker does not *skip* the fetch,
it has nothing to fetch WITH. There is no `if isLive` inside the card to get
backwards, and every simulated + DEBUG capture is byte-identical.
`testTheSimulatedPathCannotConstructTheReadAtAll` is the sweep.

**TWO ENTRY POINTS, and the difference is deliberate.** `refresh` is UNCONDITIONAL and
fires from `openScheduleCard()` — the ONE funnel all three entry points already use
for MYR-353's keyboard rule, so "the picker fetches when it opens" cannot be
half-implemented. It is fired BEFORE the keyboard settle so the request overlaps the
0.25s beat, and nothing waits on it. `ensureCovered` fires on a day-chip change and
only reads outside the held range; the open-time request already spans every chip, so
it is a no-op in the shipping horizon and exists so a longer horizon needs no second
policy.

**THE LATE ARRIVAL IS EXPLAINED, NOT RECONCILED.** When the read lands while the card
is already open on a slot it turns out to block, the picker does **not** move the
rider's selection — that would be fighting them mid-selection, which
`reconcileScheduleSelectionToFloor`'s own doc comment refuses to do. The chip dims,
the CTA goes inert, and the card's ONE muted caption slot explains, wording itself
from `own` and `pending`: "You already have a ride around this time" / "…a ride
requested around this time" / "Lunar is booked around this time" / "Lunar is already
requested around this time". **"AROUND", NOT "AT", IN ALL FOUR** — the blocked
interval is wider than the occupying ride, and "at this time" would both be false and
come as close as copy can to leaking the half-width. **"BOOKED" IS RESERVED FOR A
COMMITTED CLAIM**: `pending` changes the WORDS and never the availability, because
the create path counts pending claims in full. When both a conflict and a service
window apply, the CONFLICT wins the slot — the service line is about the whole grid,
the conflict line is about the slot named on the inert CTA one thumb-width below it.

**THE REVIEW-STAGE COPY WAS A REAL FINDING.** MYR-233's toast — *"That car just
became unavailable. Your trip's saved — try scheduling it."* — is **two lies and a
non-sequitur** when the refusal is a time conflict: the car did not become
unavailable, the rider's own noon reservation is why, and "try scheduling it" is a
strange instruction for somebody who was already scheduling. `RestError.isTimeConflict`
is a STRICT NARROWING of `isVehicleUnavailable` (so MYR-233's routing is untouched and
only the sentence branches) carried as a flag on the EXISTING
`RideVehicleUnavailableFailure` rather than a second failure type — every routing
decision is identical, and a second type would be a second `onChange`, a second
handler and a second chance to drift. That handler also **re-reads §7.22**: it is the
one moment the cached answer is known to be wrong, so going back to the picker shows
the offending slot dimmed rather than offering it a second time.

**`riderScheduleBooked` is the clean pair to `riderScheduleFloored`** — the same card,
dimmed for the other reason entirely. Its car is PARKED with NO service window, so
nothing in the frame is floored and every dimmed chip came from §7.22. It injects the
WIRE only (`DebugBookedWindowsEndpoint` mints §7.22's exact shape — RFC 3339 UTC `Z`,
resolved endpoints, range-filtered, `start`-ordered — through the shipping
`LiveRideBookedWindows` / mapping / store / `RideScheduleFloor`), and its two
bookings make both wordings reachable from one scene: the rider's OWN accepted
reservation at Tomorrow · 12:00 PM (the client's own slot, anchored through the
SHIPPING `RideRequestContractMapping.scheduledDate`, so the picker's instant and the
stub's are the same instant by construction) and somebody else's PENDING request at
5:30 PM. It also captures the late-arrival branch: the card opens on the conflicting
noon slot and the windows land underneath it. **Capture at t≈0.3s** for the
pre-arrival frame — which is also the FAIL-OPEN rendering, byte-identical to a picker
with no windows at all — and **t≈1.5s** for the settled one.

```sh
SIMCTL_CHILD_MRT_SCENE=riderScheduleBooked xcrun simctl launch <udid> app.myrobotaxi.ios
```

**"Someone else" already reached the wire; nothing pinned it** (MYR-357) — the audit
found the whole chain intact: `createBody` sends `passengerName` +
`passengerPhone`, the handler decodes both (`rideRequestCreateBody`), they persist to
`go_ride_requests.passenger_name` / `passenger_phone` (in the ORIGINAL
`0002_ride_requests.up.sql`, no ALTER), every owner response serializes through ONE
`rideRequestWire` carrying both, `RideRequestContractMapping.passenger` maps them
back, and the incoming card renders name + phone. **No backend follow-up is needed.**
What was missing was any test: both fields are OPTIONAL on
`RideRequestCreateRequest`, so dropping either throws nothing, fails no decode, logs
nothing and still answers `201` — the MYR-362 shape exactly, pointed forwards.
`PassengerWireTests` now pins both directions including the ENCODED bytes.

The audit's one real defect was a **fixture DEFAULT with no grep signature**, the
class CLAUDE.md already warns about: `RideRequestSearchContent.requesterName` read
`RideRequestFixtures.fleet` directly, so on the LIVE path — where
`draftFleetMemberID` matches no fixture row — the `??` fell through to
`fleet[0].owner` and the passenger notify note told a live rider "…as soon as
**Alex** accepts", naming a persona on nobody's account. It resolves through
`fleetMember(forID:)` now, the same accessor MYR-316's `targetVehicle` uses. The
recent-passenger CHIPS were audited and are **not** a violation — they were already
gated on `!isLiveLocation` (MYR-228), and they are the prototype's own
`RECENT_PASSENGERS`, so they stay in SIM and the drift gate is untouched.

**Recents are the half of the pre-typing gap that needs no backend** (MYR-356) —
MYR-214 emptied Saved/Recent/Nearby on the live path (a Frisco rider tapping the
fixture "Home · 221 Folsom St" got a cross-country route), leaving one muted line and
a comment admitting "no session-recents store yet". `RecentDestinations.swift` is
that store, following `AccountStorage` (MYR-224) exactly — a `Sendable` seam, a
reverse-DNS `UserDefaults` key, a JSON `Codable` payload, `init(defaults:)` for
tests. **Not a MYR-228 concern**: nothing here is a fixture, so the same code runs on
both paths — a recents row in the simulator is a real choice made in the simulator.

- **Recorded on `selectDestination`, the ONE funnel that ADVANCES** (`proceedFromSearch`
  delegates to it; the idle Home/Work chips call it directly). Deliberately not
  `chooseDestination`, which only fills the field: a destination backed out of with
  "Change trip" is not one the rider chose.
- **Deduped on label + address, never on id.** MYR-237 swaps a `live-unresolved|…`
  shell for a resolved place with a DIFFERENT id, so the same café chosen twice
  either side of that resolve would be two rows under an id key.
- **The stored id is preserved verbatim**, which is what makes "selecting a recent
  behaves exactly like choosing it from search" a structural property rather than a
  second code path: an unresolved recent re-runs `resolveDraftDestinationIfNeeded()`
  on selection exactly as a fresh autocomplete row does.
- **No fabricated distance.** Live rows carry straight-line miles and 0 minutes, and
  a distance measured at choose-time is stale by the next session; `destRow` hides
  both readouts at 0, so a recent reads label + address — the prototype's own Recent
  grammar, whose rows likewise carry no icon of their own (generic `mappin`).
- **It renders only when NON-EMPTY**, and real recents take the SIM "Recent"
  section's slot when there are any — the fixture list is what stands there until
  then. A cold install has none, and `RootView.recentDestinationsStore()` boots every
  DEBUG scene against an in-memory store, so **no capture can pick up recents left
  behind by hand-driving the flow on the same simulator**. That is the whole reason a
  persistent feature does not drift a byte-stable gate.

**A draft trip does not outlive the flow that made it** (MYR-389) — r15, build
`202607311129`: *"when I tried to search it pulled up a prev route, the state
wasn't reset to a clean search."* Tapping the idle map's "Where to?" reopened his
previous booking attempt — destination filled, "Pickup Tomorrow · 12:00 PM" still
latched, the old route etching in behind the sheet.

- **The cause is an exit that ends the FLOW without ending the DRAFT.** Review's
  scheduled `confirm()` returned the rider to the idle map with a bare
  `sheetPhase = .idle` (M1 scope: a reservation starts no live trip), leaving every
  draft field where the rider left it — and the idle search bar was a bare
  `sheetPhase = .search`, which ADOPTS whatever is lying around. Two halves of one
  omission, and **neither reads as wrong at its own call site**: one is a phase
  flip after a successful submit, the other is a phase flip to open a sheet.
- **The fix is an ENTRY invariant, deliberately, and that choice is the reusable
  part.** `resetDraftToIdle` had covered five of the six ways out of the flow for
  five issues running; the sixth was added later and shipped this bug. Exit-side
  cleanup is only ever as complete as the exit list was on the day it was written.
  `SharedViewerState.enterSearchFromIdle()` / `selectDestinationFromIdle(_:)` are
  the two doors in from idle and both start from nothing, so an exit nobody has
  written yet is covered in advance. The offending exit is fixed too — it is one
  line, and a lingering draft is wrong even where nothing reads it — but the
  guarantee does not rest on it.
- **`discardDraftTrip()` is the ONE list of what a draft is**, and writing it down
  found a field both resets had been missing: **`previewPickupAnchor`**. MYR-237's
  anti-jitter anchor is pickup identity for the route cache, and
  `capturePreviewPickupAnchor` only writes into a NIL anchor — so a "reset" draft
  kept keying routes off the previous trip's pickup until a new destination
  happened to re-anchor it. It had no symptom of its own, which is why it survived.
- **A SEARCH is not about any ride but the one being typed.** MYR-381 narrowed the
  route endpoints to a ride that is still LIVE; that is the right question on
  Review/Booking/Tracking, where the submitted record IS the trip on screen, and
  the wrong one on Search. A rider who has just booked a reservation still HOLDS a
  live record, so clearing the draft alone left the sheet clean and the map behind
  it still etching the trip they thought they had left — "no route" half-delivered,
  with the more convincing half left in place. `SharedViewerScreen
  .previewRouteRequest` is `nil` on `.search` and MYR-381's accessor everywhere
  else. The route CACHE is deliberately not dropped: that reservation's geometry is
  still legitimately its own.
- **Scope: unsubmitted state only.** Nothing here touches
  `RideRequestService.activeRequest`, so the reservation keeps the rider's slot and
  keeps resuming its own surface through `reconciledPhase` — asserted from both
  ends (`RiderDraftLifetimeTests.testTheActiveRideSurvivesTheEntryReset`, and a UI
  test that the submitted ride still renders its pending pill).
- **"Works after a force-quit" is this whole class's signature**, and it is why a
  screenshot suite cannot see it: a cold scene boots from an in-memory blank, so
  every capture of `search` was correct and the app was still broken. The guard is
  `RiderDraftLifetimeUITests`, which drives the client's sequence with real taps
  (Review → submit → wait out the auto-accept → "Where to?"), because the draft
  that leaks is created by one screen, abandoned by a second and resurrected by a
  third and no single mounted view holds enough of that to prove it.
- **The view's local mirror had to be re-synced on ARRIVAL, not just on collapse.**
  `RideRequestSearchContent` seeds `query`/`pickedDestination` from the draft at
  INIT (MYR-250 item 4) and cleared them only on `newPhase == .idle` (MYR-248),
  on the reading that the draft can only end there. Whichever way the draft became
  empty, a sheet arriving over an empty draft must show an empty sheet — otherwise
  the field says "SFO · Terminal 2" over a `draftDestination` of nil, which is
  MYR-248's stale dead "Continue" wearing the previous trip's name.
- **Test-authoring trap**: iOS's own QuickPath keyboard tutorial puts a button
  labelled **"Continue"** on screen, and `app.buttons["Continue"]` finds it before
  the app's CTA — a green-looking assertion about a system dialog. The clean-search
  check is stated in the positive instead ("the pre-typing list is showing"), on an
  element the system cannot impersonate.

**The etch is a fact about the ROUTE, not about the page** (MYR-390) — the same r15
recording, second behaviour: on the destination-selected search sheet the route is
fully etched and breathing; tapping "Continue" to the "Schedule with Lunar" sheet
made the drawn line VANISH for ~0.5s (only the pickup glow dot surviving) and then
replay its 1.6s etch from zero. Same trip, same camera, and — proved by an
on-simulator trace before a line was changed — the same `routeKey`, no refetch, and
no `RiderRouteLifetime` release. **Only the VIEW reset.**

- **The cause is a parameter that keyed an ANIMATION on a PAGE.**
  `SharedViewerScreen` passed `replayKey: String(describing: sheetPhase)` into
  `RideRequestRouteMap`, whose `onChange` called `restartPresentation()` — snapping
  `etchProgress` to 0 and re-entering `.etching`, whose map content is
  `EmptyMapContent()`. The 0.5s vanish IS that empty content. It was written for an
  older client ask (*"if I leave a page and came back we should re-draw the line"*)
  and had **contradicted the comment 60 lines above its own call site since the day
  both were written** (`routePreviewActive`: "the etch plays once … then persists as
  the breathing glow through 'Continue' instead of replaying per phase"). Hoisting
  the map above the phase switch to keep ONE view identity was necessary for that
  promise and was never sufficient — the identity survived and the state inside it
  was thrown away on a prop change.
- **`RouteEtchLedger` is the memory, and it lives beside the route cache on
  `SharedViewerState`.** A pass that must happen once per trip cannot be remembered
  by whichever overlay is mounted, because the rider walks the preview from Search
  through Review to Booking. `RouteEtchPresentation.resolve` is the whole opening
  decision as one pure function, so a first arrival and a step flip ask the same
  question and can only disagree about the ANSWER.
- **Keyed on the two ENDPOINTS, deliberately not on `routeKey`.** MYR-237's
  `routeKey` leads with `route.count`, which is the right question for "re-fit, the
  geometry changed" (a straight placeholder becoming 248 points of road) and the
  wrong one for "is this the same trip" — MKDirections legitimately answers one pair
  with a different vertex count, and an etch keyed on the count would replay over it.
  A live GPS coordinate must never reach the key either, which is what MYR-389's
  `previewPickupAnchor` already exists to guarantee.
- **`replayKey`'s two jobs were separated rather than deleted.** The camera re-fit is
  now `onChange(of: bottomInset)` — the fact it was standing in for — and Booking's
  static settle is `onChange(of: etch)`. In this flow the first is a no-op, and that
  is the point: Search's preview and Review resolve to the same
  `rideRequestRouteMapBottomInset`, so the client's "same camera" was exactly right.
- **`discardDraftTrip()` forgets the ledger**, so MYR-389's entry reset still defines
  when a route legitimately restarts. Identity alone already re-etches a new
  destination; this covers the case identity cannot see — a rider who abandoned a
  trip and started an identical one.
- **Two measurement traps, one round each, both about what a screenshot of motion
  can mean.** Gold INK over the map band is dominated by the settled route's own
  breathing glow (2–3× on 2.6s), so no floor set against that swing is tight enough
  to catch a collapse. And a loose gold predicate finds the dark map's own warm road
  casings, scattered over the whole band, which held a top-to-bottom "extent" of
  0.652 straight THROUGH a collapse the ink showed plainly. The number that works is
  **coverage of the core stroke** — the fraction of image rows the 3.5pt `mrtGold`
  line crosses — which is flat to ±0.004 while the ink swings 2× underneath, because
  what breathes is a halo over a polyline that does not move. Branch: 0.699 → 0.699
  across the flip, zero collapsed frames. Defect restored: 0.699 → **0.000**, then
  0.015 → 0.078 → 0.217 → 0.421 → 0.563 → 0.683 → 0.756.

**A REFUSAL TO DRAW IS NOT A FAILURE TO DRAW, AND THE MAP HAS TO SAY WHICH**
(MYR-395, client-reported) — scene `reviewLongDistance`, modifier
`MRT_ROUTE_UNAVAILABLE=1`. r16, build `202607311641`: *"Looks like your route etch
update broke the line from being drawn: this is a major regression."* His
screenshot is the Review sheet for a 1,049 mi Grayslake IL → Galleria Dallas trip
— camera fitted across half the United States, the pickup's glow head breathing,
**no line and no words**.

**THE TRIAGE VERDICT: not MYR-390, and not a distance limit.** Three candidates,
two ruled out by measurement rather than by reading.

- **(a) A `RouteEtchLedger` regression** — the identity marked seen, the
  presentation resolved at full progress over geometry that never arrived.
  **RULED OUT on the surface he photographed**: `resolve` reaches the ledger only
  after the geometry question, so an ETCHING surface with no real route can never
  open drawn. Confirmed on-simulator too — that exact 949-mile pair etches end to
  end with the ledger live (`MRT_SCENE=reviewLongDistance`).
- **(b) MKDirections failing, with MYR-237's honest fallback doing its job.**
  **THIS ONE.** And *not* because the request is too long: measured directly,
  MKDirections answers Grayslake → Galleria in **~1.0s with 7,348 vertices**. Any
  ordinary failure of it — Apple's per-device throttle, no network, the 8s
  `AppleRideRouteProvider.deadline` — lands on the straight `[from, to]` fallback,
  `RideRoutePolyline.isReal` refuses it, and the map correctly draws nothing.
- **(c) The fallback-retry cooldown starving.** **RULED OUT**:
  `SharedViewerScreen`'s `.task(id: routePreviewActive)` re-asks every 6s against
  the store's 8s cooldown, so a retry lands about every 12s and a route that
  becomes available still arrives. Slow, never starved.

**So nothing computed a wrong answer and the surface was still broken.** The
refusal was correct and completely silent. **A map that DECLINES to draw and a map
that FAILED to draw are the same picture** — and on a cross-country fit with one
dot on it, the second reading is the obvious one. **Short trips were never
affected** (checked first, on main: `review` etches normally), so this was High and
not Urgent.

- **`RideRouteAvailability` is the third arm the surface never had.** The one
  signal was `reviewRouteLoading == (reviewRealRoute == nil)`, which goes FALSE the
  instant the fallback lands — so the screen showed nothing and simultaneously
  reported "not loading". MYR-343 / MYR-386's lesson for the fourth time: three
  situations told apart by one boolean, so one always borrows another's surface.
  `.resolving` / `.road` / `.unavailable`, resolved from the store's answer alone.
- **The in-flight wording is MYR-327's, not a second dialect.** `ExpandedRouteMap`
  has rendered `"Finding route…"` for this state since that issue; the literal is
  now `RideRouteAvailability.resolvingCaption` and the two are asserted equal. The
  settled failure is **"Can't find a route right now"**, in the repo's own
  honest-degradation grammar ("Can't reach your vehicles right now"). **"Right now"
  is load-bearing** — the store keeps retrying underneath, so it must not read as a
  verdict; and there is deliberately **no error styling, no spinner and no retry
  button**, because a rider cannot act on this and something is already re-asking.
  `.road` carries **no caption at all**, which is the whole reason every existing
  route capture is byte-identical.
- **⚠️ THE SECOND DEFECT WAS THE OPPOSITE ONE, AND IT WAS A GUARD IN THE WRONG
  PLACE.** MYR-390 wrote `resolve` with the realness check BELOW the `etch` guard,
  which reads as harmless ("a straight fallback is never etched"). But the arm
  above it does not etch either — **it draws the line WHOLE** — so `etch: false`
  skipped the geometry question altogether and the **Booking sheet rendered the
  provider's straight `[pickup, destination]` fallback as a 949-mile gold route
  across five states**. `reduceMotion: true` took the same arm, so MYR-237's
  no-straight-lines rule was also off for every rider who turns motion down.
  **A guard placed below one of the two branches it is about only guards one of
  them.** The check is first now, and the invariant is asserted against
  `Opening.drawsWholeLine` rather than a list of case names, so an opening added
  later has to answer the question instead of falling outside the test.
- **`resolve` takes the AVAILABILITY, not an `isRealRoute: Bool`**, and that is
  what fixed the frame rather than just the line. Both lineless states are
  `isReal == false`, so the bool could not tell them apart and the one that had
  already FAILED kept breathing MYR-237's working head at the pickup. Nothing may
  look busy about a fetch that finished: `.resolving` breathes, `.unavailable` is
  the new **`.lineless`** opening — no line, no motion, on any surface in any
  motion setting.
- **`.unavailable` shows BOTH endpoint dots; `.loading` still shows one.** That is
  deliberate and opposite. Withholding the drop-off is a promise that a laser is
  coming to reveal it (MYR-237's etch-completion reveal); once MKDirections has
  answered, no laser is coming, and one dot on a five-state map is the frame he
  reported. Same rule MYR-293 gave the owner surfaces: **PINS unconditionally, the
  LINE only from `isReal`.**
- **A fetch answering is not always a change to `routeKey`**, and that is how the
  map got stuck looking busy. The preview already holds the straight
  `[pickup, destination]` pair while the real route is in flight, so when
  MKDirections returns *that same pair* as its fallback the geometry does not move
  by a point and nothing re-decided. `onChange(of: effectiveAvailability)` restarts
  the presentation and writes no camera — a re-fit is a statement about the frame.
- **A caller's `.road` cannot outrank the geometry in hand.** `.road` is the
  default, so an un-migrated call site claims road geometry by saying nothing — the
  fixture-DEFAULT shape with no grep signature, in a new hat. `effectiveAvailability`
  checks the claim. It also opts out entirely when `progress != nil`, because that
  caller is the tracking/summary travelled-vs-full renderer, which owns its own
  polyline and on the rider's post-ride card knowingly draws the straight
  placeholder (MYR-327 — the one map in the app whose line is deliberately not road
  geometry, and the one that cannot be expanded).
- **`MRT_ROUTE_UNAVAILABLE=1` is the only capture route, and it injects the
  PROVIDER rather than a flag.** It swaps in `StraightLineRideRouteProvider`, which
  returns exactly the pair `AppleRideRouteProvider` returns on a throttle/offline/
  deadline loss; the shipping store caches it, the shipping predicate refuses it
  and the shipping presentation decides the frame. Orthogonal to the scene (the
  `MRT_EXPAND_ROUTE` precedent) and applicable to Review, Booking and Search alike.
  Unset — which it is for every capture — every scene runs the real Apple provider
  and is byte-identical. `reviewLongDistance` is `review` with the client's two
  endpoints swapped in and nothing else, so the pair is a clean two-coordinate
  diff and `review` itself is untouched.
- **A pure test cannot show that the SCREEN consults any of this**, which is how
  MYR-387's defect 2 and MYR-369's `VehicleRideShare.display` both survived green
  suites — so `App/UITests/RouteAvailabilityUITests.swift` drives the real launch
  on both arms and asserts the SENTENCE is on screen, plus the negative that a real
  route carries no caption at all.

```sh
SIMCTL_CHILD_MRT_SCENE=reviewLongDistance xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=reviewLongDistance SIMCTL_CHILD_MRT_ROUTE_UNAVAILABLE=1 \
  xcrun simctl launch <udid> app.myrobotaxi.ios     # the client's frame
SIMCTL_CHILD_MRT_SCENE=booking SIMCTL_CHILD_MRT_ROUTE_UNAVAILABLE=1 \
  xcrun simctl launch <udid> app.myrobotaxi.ios     # the straight-line arm
```

**"If over an hour convert to hours and min"** (MYR-395, same report) — the same
screenshot carries **"2592 min away"** and **"2623 min · 1049.2 mi trip"**. Both
numbers are right (`TripEstimate`'s closed form puts that trip at 2,623 minutes);
neither is readable. **The reason a client had to find it is that there was no ONE
place to look**: twenty-three call sites each interpolated `"\(n) min"` into their
own string, so "and what if it is more than an hour" was never a question anybody
had to answer.

`RideDuration` is that place — `text(minutes:)` (`"43 min"` / `"1 hr"` /
`"1 hr 5 min"` / `"43 hr 12 min"`), `awayText(minutes:)` for the four surfaces that
say "away", and `heroParts(minutes:)` for the three that set the number and its
unit in different type. Three rules worth keeping:

- **Sub-hour is BYTE-IDENTICAL**, which is what keeps the whole drift gate valid —
  every fixture duration in the app (3, 12, 28, 32…) is under an hour, so no
  simulated capture moves by a pixel.
- **An exact hour never says "1 hr 0 min"**, and the minutes part is always the
  REMAINDER. The way this regresses is `"\(m / 60) hr \(m) min"` — the client's own
  "never 1 hr 65 min" — which compiles, looks right at 61, and is wrong above it.
- **`heroParts` SPLITS the composed string** at its final unit rather than
  re-deriving hours, so there is exactly one place that decides whether a duration
  says "hr". A second derivation would be a second grammar wearing the first one's
  name.
- **MYR-341's 0 sentinel is untouched**: an unmeasurable pickup still renders no
  note at all rather than "0 min away", which the hour grammar must not resurrect
  as a formattable value.
- **Out of scope, on purpose**: `IncomingRequestSheet.relativeRequestedTime`
  ("N min ago" → "N hr ago") is a different grammar and already converts;
  `parkedDuration`'s `"Xh Ym"` is the car's own resting time, not an estimate; the
  Live Activity uses `Text(timerInterval:)` over an ABSOLUTE instant (MYR-172) and
  must never be handed a formatted duration; and `StoryVignettes`' tutorial
  illustrations carry baked sub-hour literals.

**One Settings footer, both roles** (MYR-395, same report) — r16: *"How come rider
screen shows guest access at bottom and other shows version?"* MYR-354 unified
everything else about these two pages and deliberately left the footer role-split,
on the reasoning that each line "says something true about the account looking at
it". Both halves were true and it was still the wrong call: **the footer is page
furniture, and furniture carrying two different kinds of fact makes one page look
like a different app.**

- **The version wins** — it is the only thing on either page a tester filing a
  report needs and cannot get anywhere else. `SettingsFooter.appVersion` is a
  `static` on the type, not a literal typed on two screens, so a third Settings
  surface cannot invent a third wording.
- **Nothing is lost with "Guest access".** The role is already the gold **"Guest"
  badge in `SettingsProfileCard`** at the top of the same page (the prototype's own
  `shared-screens.jsx:473`), and what that role can DO per vehicle is MYR-354's
  vehicle section, which answers it per row instead of as one flat claim. Re-homing
  it as a third statement is the repetition MYR-366 deleted the Account name row
  for — and the flat claim is simply FALSE for the account MYR-343 fixed: an owner
  in rider mode is not anybody's guest.
- **The stamp is READ, not typed.** The owner footer was the literal
  `"MyRoboTaxi v1.0 (24)"`; `project.yml` ships `MARKETING_VERSION 1.0.0` and a
  `CURRENT_PROJECT_VERSION` that RELEASING.md overrides per upload (r16 is
  `202607311641`), so **build "24" has never existed** — the one line whose whole
  job is to identify the build was naming a build nobody could have installed.
  `AppVersionStamp` reads `CFBundleShortVersionString`/`CFBundleVersion`. Now that
  both roles show it, a wrong stamp would be wrong twice, in front of the person
  most likely to read it.

**No straight lines, on the OWNER's two surfaces too** (MYR-293) — TestFlight,
Jul 25: *"Fake route poly line rendered."* MYR-237 settled the rule ("no straight
lines ever") and MYR-177 built the machinery, and then two owner surfaces drew
literal two-point segments anyway: `VehicleMapView`'s dispatched car→pickup leg
(whose own doc comment called it "a straight car→pickup route") and
`IncomingRequestSheet`'s mini-map, whose header still read "M1 has no routing
API". Both now consume the SAME `RideRouteStore` the rider has used since
MYR-177 — same MKDirections source, same 8s deadline, same 6-dp cache key, same
deviation-driven refetch.

- **The rule is ONE predicate now.** `RideRoutePolyline.isReal` (`count > 2`) was
  inline on the rider's review map; the two owner surfaces had no predicate at
  all. `RideRequestRouteMap` reads it too, so a new surface cannot invent a looser
  test. **`drawable` returns EMPTY for a fallback**, and both owner surfaces draw
  their PINS unconditionally and their LINE only from that — a pickup we know is
  a fact, a route we haven't fetched is not.
- **Both surfaces get a REAL route, neither gets pins-only as a resting state.**
  The incoming card is what an owner accepts or declines a ride from — across
  town or around the block is the decision — so one MKDirections call per card is
  worth it, and the pair is fixed for the card's life so it is exactly one call.
- **`AppleRideRouteProvider` in BOTH modes**, matching `SharedViewerState`'s own
  store verbatim (MYR-177, client-approved). MYR-293's text suggests a
  straight-line provider in SIM "so drift-gate scenes stay pixel-identical" — that
  reasoning does not survive its own rule (a straight provider yields 2 points,
  which must not be drawn, so the scene changes either way), and it would mean
  these two surfaces could never PHOTOGRAPH the road route the issue adds. That is
  the repo's own "cold scenes passing while real paths fail" lesson pointed at a
  drift gate.
- **Leg 1 gained the two guards leg 2 already had.** A new PICKUP drops the cache
  outright — real road geometry rendered to the WRONG place is worse than the
  straight line this removed, and far more convincing. And a cached 2-point
  FALLBACK now retries on `fallbackRetryCooldown`: deviation alone cannot bring
  the route back, because **a car following the straight fallback never strays
  from it**, and the caller no longer draws that fallback to paper over the wait.
- **The owner's store lives on `OwnerHomeState`**, not `HomeScreen` — `RootView`'s
  `switch ownerTab` destroys the view, and a per-mount store would spend a fresh
  throttle-budgeted call on every tab switch.
- **No camera is touched.** Routes are map CONTENT; a polyline landing late
  changes what is drawn on the frame, never the frame (the MYR-237 overlay
  pattern). The incoming card's camera fits the two ENDPOINTS via
  `initialPosition`, written once, so a route arriving later cannot re-frame a map
  the owner is already reading.
- **`MRTRouteStroke.aheadOpacity` (0.85)** — the client's *"Route poly line feels
  hard to see"*. `RouteLine`'s 0.30 is the prototype's alpha for an ILLUSTRATED
  route; MYR-234 already moved the rider's ACTIVE leg to 0.85 and the owner map
  was still on 0.30, so at trip start (progress ≈ 0) the whole route was the dim
  wash. Named in DesignSystem and read by both surfaces — identical number, so
  every tracking capture is byte-identical.

**The honest driving hero** (MYR-294) — three TestFlight reports, one cause:
*"When no navigation, state just shows navigating"*, *"Taking a long time to
populate destination name even though route appeared"*, *"I don't like the dot
next to the destination."* `DrivingTrip.destinationName` was a non-optional
`String`, so `VehicleContractMapping` substituted the literal `"Navigating"` — and
the hero, with no way to know the difference, wrapped that word in a whole
fabricated trip: "Arriving in 0 min", an "ETA" of `Date() + 0`, a progress bar at
its 5% clamp, and a Route leg reading "· " because `destinationCity` is parsed
from an address the wire never live-broadcasts.

- **`DrivingNavigation` is THREE cases, not a `String?`** — `.none`,
  `.resolvingDestination`, `.destination(name:city:address:)`. Two of them are
  nameless and they render differently, and MYR-343's lesson is that three
  situations told apart by one flag means one always borrows another's surface.
- **The predicate is the ATOMIC GROUP, not `destinationName`.** The contract's
  navigation group is all-or-nothing and its nullability is *"Null = no active
  navigation"*, so `navigation(from:)` asks whether ANY member is present.
  Gating on `destinationName` — the obvious implementation — would classify the
  first ~60s of every real trip as "not navigating", because Tesla emits
  `RouteLine` and `DestinationName` independently.
- **`DrivingHeroElement.resolve` is the whole render rule, and it is
  CLIENT-DIRECTED.** The first build shimmered an `MRTSkeletonBar` in the
  destination slot while the name was pending. He rejected it on sight: *"why are
  you skeleton loading when no route that looks so weird and useless"*, then
  stated the rule — *"if no route then no need to show a route, if a route is
  about to arrive then sure thats fine bc we're loading something"*. **The test is
  whether a fetch is ACTUALLY RUNNING**, and for the destination name none ever
  is: Tesla either pushes it or does not, so the shimmer had no deadline and no
  honest end state. `DrivingHeroElement` therefore has **no placeholder case at
  all** — asserted, so it cannot grow one — and the elements gate as: title +
  Route section need a NAMED destination; the arrival pair needs active navigation
  AND `etaMinutes > 0` (0 is reachable under live nav, inside the server's 500ms
  accumulation window); the progress bar needs active navigation AND a real
  fraction (`TripProgressBar` CLAMPS to 0.05, so 0 draws the orb 5% along); the
  location line renders exactly when there is no journey to describe.
- **The Route SECTION goes whole, rather than degrading.** It is a two-ended
  statement, and one unnameable end leaves nothing to list — a dot with a
  placeholder beside it is the stacked-chrome-for-no-content shape MYR-347 was
  about. `RouteLeg.title` is non-optional again; `RouteLeg.subtitle` is optional,
  because a live leg with no address used to render an empty 12pt line.
- **`homePeekHeightDrivingNoNavigation` (234) is MYR-345's rule pointed the other
  way**: a live-only hero that DROPS lines gives its room back rather than banking
  it as a gap above the nav. It is tuned to **INK, not layout**, and the two
  disagree by ~4pt here because the heroes end on different kinds of thing — the
  trip hero's last element is `TripProgressBar`, whose 15pt orb overflows its own
  14pt frame (~2pt of ink BELOW the box), and the honest hero's is a 12pt text
  line (~2pt ABOVE it). Measured full-frame: 42.7pt of clearance for the
  navigating hero, 46.7pt at a layout-parity 238, **42.7pt at 234**.
  `OwnerPeekBandTests` carries the 4pt offset explicitly rather than widening its
  tolerance to hide it. `.resolvingDestination` keeps the FULL driving band — the
  arrival pair and the bar are real, so the block does not resize when the name
  lands.
- **Every simulated hero is untouched.** `VehicleFixtures.cybercabTrip` is
  `.destination("Duarte's Tavern", "Pescadero", …)` and the sim snapshot starts at
  progress 0.42 with `etaMinutes ≥ 1`, so all three gates pass and `ownerHome` /
  `ownerDrives` render exactly what they did. Scenes `ownerDrivingNoNav` /
  `ownerDrivingResolvingDestination` are live-path-only by construction.
- **THE WIRE DOES CARRY NAV**, so the named variant is reachable and this is not a
  backend gap — see the enabler note below.

**Expanded route viewer** (MYR-327) — tapping the map on the **Drive Summary**
hero (owner Drives → a drive, and the rider's Ride History → a completed ride —
one screen, `DriveSummaryScreen`) or on the **rider live tracking** map opens
`ExpandedRouteMap`: a full-bleed, user-driven map rendering the SAME
`@MapContentBuilder` its host draws inline (`driveRouteMapContent` /
`TrackingRouteMapContent.content`), so the two can never diverge. Each surface
also carries a visible `ExpandRouteButton` chip (Drive Summary: in the floating
nav beside Share; tracking: one button-stack above the recenter control). The
rider's POST-RIDE summary card is deliberately NOT expandable — its polyline is
always the straight 2-point `[pickup, destination]` placeholder, never real road
geometry, so blowing it up full-screen would present a fabricated route.

On the expanded viewer the **USER owns the camera**: `ExpandedRouteCamera` issues
exactly TWO programmatic writes for the view's whole life — the initial fit
(once, ever) and an explicit recenter tap. A streaming fix, a leg flip, or the
real polyline replacing a fallback can NOT re-fit it, so the MYR-222 loop class
is structurally impossible rather than tuned away (probe verdict: 1 write across
30s of moving fixes with the leg flipping). Two traps this cost a round each:
MapKit settles its own `.automatic` framing BEFORE `onAppear` runs (so
pre-fit settles must classify as layout, not gesture), and a second nested
`ignoresSafeArea` on a child of an already-full-bleed parent pushes that child
past the parent's bounds, where it still draws but its taps are dropped.

**MYR-334 (polish round, two TestFlight items on the day-old viewer):**

- *"The drive map opening up is a bit glitchy, needs to be smooth"* — device-only,
  which is the tell. Two causes, both structural. (1) The open animated a
  `scaleEffect` over a live `MKMapView`; a *changing* scale makes MapKit
  re-render its vector tiles every frame, and the combined `.opacity` forces the
  whole full-screen map to composite off-screen as a group while it does. The
  transition is now a **pure opacity cross-fade** — the surface is laid out ONCE
  at final size and only a compositing property animates. (The scale also left a
  3% border of the screen it came from visible for the whole transition, on a
  takeover that is supposed to be full-bleed.) (2) The map was **born inside the
  animation**: `cameraPosition` started `.automatic`, so MapKit framed the content
  itself, requested tiles for that framing, then threw them away when the
  `onAppear` fit landed — a re-frame mid-transition. `ExpandedRouteMap.init` now
  seeds `cameraPosition` with `ExpandedRouteCamera.fitRegion` (a PURE function of
  the route, no view height), so MapKit's first layout is the final one. Frame
  captures pin it: **before**, the route's bounding box moves three times across
  the open and is still moving after it lands; **after**, it is identical in
  every frame from the first one the map draws.
- *"the Apple Maps legal icon and the start to destination at the top are cutting
  off"* — the header sat at a flat `expandedRouteChromeTop` (52) from the physical
  edge, which on a Dynamic Island phone runs the title into the status bar; and
  the map reserved NO bottom band, so MapKit drew its attribution into the
  home-indicator strip. The header offset is now a FLOOR
  (`max(chromeTop, windowSafeAreaTop + expandedRouteChromeSafeGap)`) — still
  physical-edge geometry, just never colliding with system UI — and the chrome
  bands are declared to MapKit as `.safeAreaPadding`, which lifts the attribution
  clear. **Declaring them as padding replaces the `insetRegion` pre-compensation
  of the written region**: MYR-237's rule (under `safeAreaPadding` MapKit already
  fits a `.region` into the unobstructed band) means compensating in both places
  renders the route half-size. Keep the top/bottom bands EQUAL — a symmetric band
  leaves the settled camera's centre identical to the written one, which is the
  only reason `CameraSettleLedger` still recognises the fit's own settle instead
  of offering a recenter on a camera nobody touched.

Capture it with `MRT_EXPAND_ROUTE=1` (DEBUG, orthogonal to the scene — see the
modifiers below): `MRT_SCENE=ownerDrives MRT_OPEN_FIRST_DRIVE=1
MRT_EXPAND_ROUTE=1` for the client's own surface, `MRT_SCENE=trackingLeg1|
trackingLeg2 MRT_EXPAND_ROUTE=1` for the rider's. Capture the tracking one at
t≈2s to get the honest "Finding route…" line (before MKDirections lands) and
later for the resolved road route. Unset, every existing scene is unchanged.
The pan/pinch/recenter states cannot be reached headlessly at all —
`App/UITests/ExpandedRouteUITests.swift` synthesizes those touches and attaches
the captures to the xcresult (`xcrun xcresulttool export attachments`).

**The Share tab is client-directed** (MYR-347 — **a DELIBERATE, CLIENT-DIRECTED
DEVIATION FROM THE PROTOTYPE**, the second one after MYR-346's FSD celebration,
and the same standing precedent: **client outranks prototype**). TestFlight, Jul
29: *"This page is just awkward. I know the prototype looks like this but weird
text in the middle saying viewers 0 and then one pending request below. Using
proper clean iOS design on this page and make it look better."*

What he photographed was a MISSING STATE, not a styling miss. screens.jsx:113
renders `VIEWERS · {n}` **unconditionally** and :127 renders `PENDING`
conditionally, so an account with nothing accepted and one invite out — **the
state every owner is in on day one** — got a header counting to zero, a
consolation sentence, and then a second header over a single row. Three pieces of
chrome for one row of content. It reproduces in the running prototype (revoke all
three fixture viewers on the Share screen in Flat and it is his screenshot
exactly), which is why this is the prototype's grammar and not a port defect.

- **The rule is structural, not a checklist item.** `ShareRosterState.resolve` is
  a pure function of the two lists the `ShareService` seam already publishes, and
  a section with no rows **is not in the model**. So "collapse an empty section"
  is not something a call site can forget: `ShareRosterSection` is non-empty by
  construction, its `count` is always ≥ 1, and the count badge cannot render "0".
  `ShareRosterStateTests` sweeps the whole 4×4 matrix and asserts it.
- **Two arms, four states.** `.empty` (nothing accepted AND nothing pending) is
  the hero — icon, "No one has access yet", one explainer, one gold CTA.
  `.populated` is an "Invite someone" action row plus one inset grouped CARD per
  non-empty section, header + count badge above each. The empty arm renders NO
  action row: there the hero owns the only CTA, which is the point of having one
  state model.
- **Deviations from the prototype, and why.** (1) The bare header+row stacks
  become **cards with inset hairline separators** — the client asked for iOS
  grammar and iOS groups list rows. (2) The per-row `Revoke` pill and the
  `Resend`/`Cancel` text buttons become **one overflow `Menu`**, so a row's width
  belongs to its content and the destructive styling is the system's. **NOT a
  `List` with swipe actions**: swipe would come free, but so would
  `UITableView`'s background/separator/selection/inset behaviour, which the
  flat-only token system would then fight on every property. (3) "VIEWERS · N"
  becomes **"Shared with" + a badge** and "PENDING" becomes **"Invited"**.
  (4) The hero headline is **"No one has access yet"**, not "Share your Tesla" —
  the screen header six points above it already says that, and a hero restating
  the heading is the same stacked chrome the client objected to. (5) The
  page-level recipient field is gone; see the composer below.
- **"Shared with", NOT "Riding with you"** — the accepted list holds every tier
  and `live` (the composer's DEFAULT) grants location only; §7.5.0 has the server
  **403** a ride created below `rides`, and `riderWatchOnly` exists precisely so
  the client never offers what will fail. A header asserting rides about that
  list is the same class of claim, made from the owner's side. It is also the
  header `SettingsScreen` already puts over these very rows, so the two surfaces
  read as one product. Pinned by
  `testTheAcceptedHeaderDoesNotClaimRideAccess`.
- **The composer is a FLOW now, and the extra step is a keyboard rule rather
  than a design flourish.** The recipient field moved off the page into step one
  of the ONE `mrtConfigSheet`; step two is MYR-344's configuration surface
  unchanged. It is a separate STEP and not a field added to the configuration
  because a text field inside that tall sheet is exactly MYR-344/MYR-353 again —
  a keyboard over the "Send invite" CTA on a sheet that does not scroll. Step one
  is short by construction (title, sub-line, one field, one button), so it holds
  a keyboard with room to spare, and `openConfig()` force-resigns and pays
  `MRTKeyboard.dismissalSettle` **before** the step changes, so the tall content
  never measures a shrunken container. `ShareComposerKeyboardUITests` drives the
  client's original sequence through the new shape and got STRICTER: the keyboard
  is now up inside the same sheet that must survive it.
- **`PendingInvite.sent` is TWO vocabularies, and composing onto it unexamined
  is a bug with no compiler signature.** `SimulatedShareService` writes the
  prototype's bare relative ("2d ago"); `LiveShareService.sentLabel` writes a
  sentence fragment ("sent 2d ago"), a bare "sent" when `createdAt` will not
  parse, and **"expired"** when §7.5.2's expiry has passed and the code silently
  stopped redeeming. The first build of this screen prefixed "Invited " onto it
  and put **"Invited sent 2d ago"** into a live capture — and would have shipped
  "Invited expired", which reads as a date. `ShareInviteDetail` is the one place
  that normalizes it, with its own tests, and an expired invite now SAYS so.
- **`ViewerRow` / `RevokePillButton` are deliberately untouched.**
  `SettingsScreen` consumes `ViewerRow` and is being restyled separately
  (MYR-354); a half-migrated row shared across two in-flight redesigns is how
  both end up wrong. The Share tab's rows live in `ShareRosterViews` instead.
  `PendingRow` went with the move — it had exactly one consumer.
- **This page's drift-gate scenes changed ON PURPOSE**, and the rest of the app
  did not. `ownerShare` / `ownerShareLive` are the redesigned mixed states;
  `ownerShareEmpty` / `ownerSharePendingOnly` / `ownerShareAcceptedOnly` are the
  matrix arms (the last of which is HIS state and had no capture route at all
  before — `SimulatedShareService` seeded the fixtures in its `init`, so the
  roster is now an `init` parameter defaulted to them); `ownerShareComposer` /
  `ownerShareComposerAccess` are the two composer steps, seeded through the
  SHIPPING `openConfig()` so the capture is behind the real validation.
  `ownerSettings` — the one other consumer of this data — is **byte-identical**,
  which is the guard that the Settings surface was not touched.

**The grant is EDITABLE now, and the vehicle's switch moved onto this page**
(MYR-369, contracts **0.23.0**) — scenes `ownerShareControls` /
`ownerShareVehiclePaused`. Before this issue a share's access was **fixed for the
life of the row**: the contract said so in as many words, and changing what
someone could do meant revoking them and sending a fresh invite. `PATCH
/api/invites/{inviteId}` replaces that, and the tier it replaces is retired with
it.

- **THE TIER IS NOW TWO INDEPENDENT FLAGS.** `ShareInvite.allowRides` and
  `ShareInvite.suspended` are owner-only, accepted-rows-only, and are the truth;
  `sharePermission` survives as a **derived compatibility projection** the server
  recomputes on every read (`allowRides` true → `rides`, else `live`). So the
  pre-MYR-369 rule that consumers compare tiers with a cumulative `>=` is now
  **wrong**, and `SharePermission.rank` / `grants(_:)` are **deleted rather than
  deprecated** — a comparator that still compiles is a foot-gun, and every call
  site had to be visited anyway. `SharePermission.allowsRides` (equality) and
  `ShareInvite.allowsRides` / `.isSuspended` are the only reads.
- **`live_history` IS RETIRED AND NEVER EMITTED**, and the third invite option
  went with it. Two things killed it independently: the drives surfaces are
  **owner-only** as of MYR-369, so no share preset opens them at all
  (`SharedVehicleGrant.grantsHistory` is now `false` for every viewer, which is a
  real behaviour change, not a tidy-up); and a preset that cannot come back from
  the server is a one-way trip. The enum member **stays** for decode compat and
  `ShareTierMapping.tier(forWire:)` folds it to `.live` — but no
  `ShareAccessLevel` case can produce it, so sending it is unreachable by
  construction rather than by care.
- **THE TWO ABSENCE RULES POINT IN OPPOSITE DIRECTIONS**, which is the single
  most swappable thing here. An absent `allowRides` falls back to the derived
  `permission` (`rides` → true); an absent `suspended` reads as **NOT suspended**.
  *Absence is never suspension.* Both are spelled once, in the Kit, for the same
  reason `VehicleRideShare.isPaused` is.
- **The vehicle-level ride-share toggle moved to the TOP of the Share tab** —
  same field, same `PUT /api/tesla/vehicles/{id}/ride-share` (§7.18), same
  `VehicleRideShare.rowCaption` strings. It was the last row of the owner sheet's
  "Status & location" card, three detents down inside a scroll, beside the car's
  location and range. That is where the FIELD lives; it is not where its
  CONSEQUENCES are. It also makes the per-viewer Rides switches legible, since
  they are gated on it — and a gate the owner cannot see is a control that
  mysteriously does nothing. **The Share tab has no vehicle selection**, so the
  card renders **one row per owned vehicle** rather than inventing a fleet-wide
  semantic the server does not have or silently governing only the first car.
  It is a MOVE, not a copy: `StatusLocationSection` no longer takes a
  `rideShare:` model, `VehicleControls` no longer has `rideShareEnabled` /
  `onSetRideShareEnabled`, and neither does `HomeSheetContent`. That card is
  again exactly what it was before MYR-342 — the car REPORTING its situation,
  with no row where the owner answers. Two switches for one field on two screens
  would be worse than either placement.
- **MYR-360's PAUSE WARNING IS RE-HOMED, AND THE DISCLOSED GAP IS CLOSED (fix
  round).** Turning ride sharing OFF reads the car's upcoming ACCEPTED
  reservations first and warns before stranding a booked rider
  (`RideSharePauseFlow`). MYR-369 first shipped that flow still bound to the
  per-vehicle `VehicleCommandExecutor` seam — it committed through `executor
  .setRideShareEnabled` and raised failures as executor NOTICES — while the Share
  tab writes §7.18 straight through `ShareService`. So the feature did not
  degrade, it **silently stopped happening**: a tap that used to ask about booked
  riders just paused the car.

  **The fix is to name what the flow actually needed, which was never an
  executor**: somewhere to commit, and somewhere to say a failure out loud.
  `RideSharePauseTarget` is those two methods and nothing more, and
  `RideSharePauseFailure` is the two ways this can fail. The DECISION, the read,
  the dialog and all three answers are untouched — `RideSharePause.decide` is
  byte-for-byte what MYR-360 shipped, and `RideSharePauseWarningTests` still
  drives it through a real `LiveVehicleCommandExecutor` (via a test-local
  adapter), because that committer is the more demanding of the two: it is the
  one with a rollback to observe. **Forking the flow for the new call site is how
  two surfaces come to disagree about whether a rider was stranded.**

  `ShareServiceRideSharePauseTarget` is the Share tab's conformance. It is bound
  to ONE vehicle id — the card renders one row per owned car, so "which car is
  this dialog about" has to travel WITH the commit target — and it reports
  failures as this screen's own quiet toast rather than a second grammar. The
  copy is `VehicleCommandNotice`'s own, **asserted equal** so a relocated control
  cannot start speaking a new dialect. Flipping ON still never warns.
  `InvitesScreen` takes the SAME `upcomingReservations` instance `HomeScreen`
  did, so two surfaces can never read different answers about one car.

  **The owner sheet's side is DELETED, not left dormant** — `resolvedRideShare`,
  `setRideShareEnabled`, the pause dialog, `RideShareRowModel` and `RideShareRow`
  all went, along with `HomeScreen`'s `upcomingReservations` and
  `DebugScene.rendersLiveRideShareToggle`. They had been unreachable since the
  move, and unreachable code that still compiles is what let the gap sit open
  looking wired.
- **⚠️ THE MYR-358 DERIVED-OFF WAS LOST IN THE MOVE, AND NOTHING FAILED (fix
  round).** This is the sharpest lesson of the relocation and it generalizes well
  past this feature.

  While a car is IN SERVICE the ride-share switch renders OFF and INERT with its
  own caption, the owner's stored preference is untouched underneath, and nothing
  is written on either transition (client-approved, MYR-358). The relocated card
  read the stored value straight through —
  `VehicleRideShare.isEnabled(override ?? vehicle.rideShareEnabled)` — so a car
  sitting in a workshop advertised rides it could not give.

  **`VehicleRideShare.display` kept passing every one of its own tests while
  having ZERO call sites in shipping code.** A pure function with good tests and
  no callers is the quietest regression available: every assertion about it stays
  green while the behaviour it describes is gone from the product. Neither the
  compiler nor the suite nor a screenshot of `ownerShareControls` (whose car is
  not in service) could have caught it. **Relocating a control means re-checking
  what DERIVED it, not just what it wrote** — and the guard that works is
  asserting through the surface's own model, not a second time through the pure
  function.

  The restoration is STRUCTURAL rather than diligent. `VehicleRideShareRow` now
  carries the two FACTS (`storedEnabled`, `isInService`) and **derives**
  `isEnabled` / `isInteractive` / `caption` through `VehicleRideShare.display`
  verbatim, so a row cannot be constructed holding a position that disagrees with
  itself and a future service cannot re-implement the rule differently.
  `Vehicle.isInService` threads the fact off the §7.0 list the tab already
  fetches, folded through the EXISTING
  `VehicleContractMapping.badgeStatus(forSummary:state:)` — not a second status
  rule, so the card and the sheet's In Service badge cannot disagree about one
  car.

  **A second-order bug fell out of the same read**: `LiveShareService`'s rollback
  took `previous` from `isEnabled`, the DERIVED position. On any failed write to
  an in-service car that would have written a service visit's temporary off into
  the owner's standing preference — persisting exactly the value deriving it
  exists to avoid. It reads `storedEnabled` now, and that is asserted directly
  rather than left to the view modifier that currently makes it unreachable.

  **The per-viewer Rides caption tells the two reasons apart.** Both kinds of off
  disable the switch — nobody can request the car either way — but "Ride sharing
  is off for {car}" describes a switch the owner set and can unset, and would
  send them to a control that is itself inert. In service reads as the FACT and
  that it resolves itself, following `VehicleRideShare.inServiceCaption`'s own
  reasoning (and, like it, avoiding the word this app has spent on the owner's
  own decision). **Suspension still outranks both**, asserted.
- **The stale scenes are RESOLVED (fix round): two retired, four re-pointed.**
  Six scenes booted the owner sheet to photograph a row that had left it —
  passing, every time, about a control they could no longer see.

  `ownerRideShareOn` / `ownerRideSharePaused` are **RETIRED as genuinely
  redundant**: `ownerShareControls` / `ownerShareVehiclePaused` already are that
  pair — the same two positions of the same switch on the same card, as a
  deliberate one-toggle diff. Four names for two frames is how a scene list stops
  being read.

  `ownerRideSharePending`, `ownerRideShareInService`, `ownerRideSharePauseWarning`
  and `ownerRideSharePauseWarningMulti` **re-point to the Share tab**, because the
  states they document are still real and still uncaptured: a write in flight, the
  derived-off arm, and the two warning arms. They now resolve through
  `initialOwnerTab → "invites"` and `shareServiceOverride`; their
  `DebugVehicleDetailsFleet` arms, their `.fraction(0.68)` sheet anchors and
  `rendersLiveRideShareToggle` are all gone, since none of them reads a surface
  these scenes still visit. `flipsRideShareOnBoot` now drives
  `InvitesScreen.setVehicleRideShare` — a stand-in for the TAP only, always the
  OFF direction, since only OFF warns.

  `ownerRideShareInService` is the REGRESSION GUARD for the derivation and keeps
  seeding `rideShareEnabled: TRUE` on purpose: the capture is proof of something
  only if the switch it shows OFF is one the server says is ON. A scene seeding
  `false` would render an identical frame for the wrong reason and would still
  pass with the derivation deleted again.

```sh
SIMCTL_CHILD_MRT_SCENE=ownerRideShareInService xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=ownerRideSharePending xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=ownerRideSharePauseWarning xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=ownerRideSharePauseWarningMulti xcrun simctl launch <udid> app.myrobotaxi.ios
```
- **The per-viewer row is not `ShareRosterRow` with switches bolted on.** Two
  labelled switches do not fit beside a name and two lines of text at 393pt, and
  stacking them on the trailing edge gives the owner two unlabelled toggles whose
  meaning is positional. They get their own sub-rows, indented to the text column
  exactly as the separator is. **The PENDING row keeps the plain
  `ShareRosterRow`**, which is what makes "no switches until accepted" visible at
  a glance — and `PATCH` answers `409` on a pending row, so that rule is enforced
  rather than merely drawn.
- **A DISABLED RIDE SWITCH IS DIMMED AND INERT, NEVER HIDDEN OR RE-DRAWN OFF.**
  The contract is specific: a suspended grant keeps its flags and restoring
  returns exactly what it had, so the owner has to see what is coming back.
  `ownerShareVehiclePaused` is the capture that proves it — Jonas's Rides toggle
  sits dimmed-GOLD (stored on) directly above Mira's dimmed-GREY one (stored
  off). Re-drawing either as plain off would be a claim about the stored value
  that is simply false.
- **Precedence in the copy is not arbitrary.** `ShareViewerControls.resolve`
  checks suspension FIRST, because it is the stronger and more specific fact: a
  viewer suspended on a car whose ride sharing is *also* off must be told they
  cannot see the car at all. Naming the lesser reason would send the owner to the
  wrong switch. The subtitle says the CONSEQUENCE and names the person ("Paused —
  {name} can't see this car"); "suspended" is the wire's word and means nothing
  to an owner.
- **Optimistic with rollback, and the ROLLBACK IS THE SERVICE'S JOB** — it holds
  the exact row it replaced. A view re-deriving "the opposite of what I just
  sent" would be guessing at a value the server may have changed underneath it.
  Leaving an optimistic position up is the failure that matters: an owner walks
  away believing they paused someone who still has full access. The vehicle
  switch adopts the server's **echo** rather than the bool it sent, same rule as
  MYR-342.
- **ONE SCREEN ROW IS N SERVER ROWS**, so a per-viewer edit fans out over the
  whole group exactly as revoke does — patching only the first would leave the
  person able to ride the owner's other car from a switch that says otherwise.
  The accepted-row grouping key gained BOTH flags: two grants that disagree must
  stay two rows, or one pair of switches would render one grant's state while
  writing to both.
- **The viewer's half is an ABSENCE, not a marker.** Suspension is enforced by
  removing the grant from the access set, so a suspended car does not arrive
  flagged — it **stops being in `GET /api/vehicles`**. A client looking for a
  "suspended" field on the viewer side finds nothing and concludes all is well.
  `RootView.adoptRiderVehicle` now **releases on `.empty`**: before this it
  returned without touching anything, so the shell showed an honest empty screen
  while `SharedViewerState` and the live socket stayed pointed at a car the
  account no longer had access to. `.unavailable` still does NOT release — a list
  that did not *answer* is not evidence the car is gone. One caveat is recorded
  rather than closed: the server does not tear the socket down on suspend, so an
  already-open stream keeps delivering until it reconnects (websocket-protocol.md
  §10 DV-09, server-side fix tracked as **MYR-373**); `adopt(nil)` dropping it on
  the next list read is the earliest honest moment this side has.
- **`DebugShareEndpoint` stores its rows in a REFERENCE box now.** The shipping
  service re-reads the list after every write, so a stub that patched a value
  copy would answer `200`, re-read the untouched seed, and snap the switch back —
  a capture of a broken toggle produced by a broken stub. Every switch in both
  scenes is genuinely live: real optimistic write, real PATCH (partial body,
  derived `permission`, `409` on pending), real re-read. Both scenes are
  live-path-only by construction — the flags exist only on a §7.5.2 owner listing
  — so `ownerShareEmpty` / `ownerSharePendingOnly` / `ownerShareAcceptedOnly` and
  both composer steps are unchanged. **`ownerShare` DID change on purpose**: it
  grows the vehicle card and the switches, and its fixture roster moves the middle
  persona off the retired `history` preset onto `allowRides`, with the third
  persona now SUSPENDED — a state that had no fixture at all before.
- **The decode trap, pointed forwards** (MYR-362's lesson): both flags are
  OPTIONAL BOOLS, so a wrong key decodes silently to `nil` — and `nil` on
  `suspended` reads as NOT suspended, i.e. a mis-keyed fixture would show a paused
  viewer as having full access while every decode test passed. The guards are raw
  fixture keys (`share_invites_list_flags.json` asserts the flags are on accepted
  rows and **absent** from the pending one), raw encoded PATCH-body keys, and a
  test that pins every fixture key against what the GENERATED type actually
  produces — the check MYR-362 did not have, since its hand-authored type and its
  fixture were written from the same misreading and agreed with each other.

```sh
SIMCTL_CHILD_MRT_SCENE=ownerShareControls xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=ownerShareVehiclePaused xcrun simctl launch <udid> app.myrobotaxi.ios
```

**A PUBLISHED LOADING SIGNAL THAT NO SCREEN READ** (MYR-386, client-reported) —
scenes `ownerShareLoading` / `ownerShareUnreachable`. TestFlight, build
`202607311129`: *"Need to add the skeleton loading to this page. It flashes no
one added then appears."*

`ShareService` has published `isLoading: Bool` and `statusMessage: String?` since
MYR-184 and **`InvitesScreen` read neither**. So the tab resolved its entire
render from the two arrays those signals were meant to qualify — arrays that start
`[]` on the live path — and an empty array IN FLIGHT is byte-identical to an empty
array that came back empty. The screen answered both with `.empty`: the hero, the
explainer and the gold CTA, i.e. the most definitive thing it can say, over a
fetch that had not answered. **A signal with no consumer is worse than no signal:
it makes the surface look wired, and no test, compiler or screenshot disagrees.**
This is MYR-343's lesson for the third time (`hasLoaded && grants.isEmpty`, then
`RiderSettingsVehicleSection`, now here) — three situations told apart by fewer
arms than they have, so one always borrows another's surface for a frame.

- **The phase REPLACES the two booleans rather than joining them**
  (`ShareRosterLoadPhase`: `idle` / `loading` / `loaded` / `failed(String)`).
  They could not express the flash's own state: `isLoading == false,
  statusMessage == nil` was BOTH "loaded, genuinely empty" and "nobody has asked
  yet". `ShareRosterState` grows `.loading` and `.unavailable(String)` to match,
  so the empty hero is **reachable only from a completed fetch** — structurally,
  not by care.
- **`.idle` shimmers WITH `.loading`, deliberately.** `InvitesScreen.task` calls
  `load()` unconditionally on appear, so on this screen "not asked yet" is always
  "about to ask"; splitting them would put the hero on screen for exactly the one
  frame the client photographed. The standing rule (shimmer only while a fetch
  genuinely runs) is kept by the SERVICE, which leaves `.idle` the moment it
  establishes there is nothing to fetch.
- **ROWS IN HAND OUTRANK EVERY PHASE**, and this is not a nicety.
  `LiveShareService` re-reads the whole list after every mutation and on every
  appearance of the tab, so a re-read that blanked a populated roster into a
  skeleton — or into a failure screen — would make a REVOKE look like the list
  falling over. Same rule `LiveSharedVehicleCatalog` applies when it leaves the
  last-known grants standing.
- **THE SECOND FLASH WAS THE EMPTY FLEET, and it is the sharper half.** §7.5.2 is
  per-vehicle, so `performLoad` short-circuits when `ownedVehicles()` is empty —
  correctly — but it could not tell "this account owns no cars" from "the vehicle
  list has not answered yet" and answered both with "nothing is shared". On a cold
  boot that is the flash; worse, the `.task` had already fired and **nothing
  re-asked when the fleet landed**, so a Share tab opened during a cold boot sat
  on the empty hero for the rest of the session. `ShareFleetState`
  (`resolving`/`resolved`/`unreachable`) is a closure into the SAME started fleet
  `shareableVehicles` already reads — no new fetch — and `InvitesScreen` re-asks
  on the vehicle IDS changing (ids, not rows: telemetry rewrites charge and
  location on those same `Vehicle` values every second).
- **A FAILED READ IS NOT AN EMPTY LIST.** "No one has access yet" is a claim about
  the ACCOUNT and a failed fetch does not support it — and an owner who believes
  it will re-send an invite that already landed. `ShareRosterUnavailable` carries
  `LiveShareService.unreadableMessage` verbatim, mirrors
  `SharedVehiclesUnreachableScreen`'s second line, and has **no retry button and
  no CTA at all**: recovery is the low-friction one (a resume re-asks), and
  minting a code onto a roster the app cannot see is not an offer to make.
- **The ride-sharing card gets a placeholder too**, because it reads the very
  vehicle list the roster's fetch is keyed on: with no cars in hand it drew
  NOTHING, so the page's first card popped in and shoved the roster down when the
  fleet landed. Its switch's slot gets a block while the roster row's overflow
  menu deliberately does not — **the ellipsis is an affordance that exists
  regardless of the data, so a block there invents a button; a toggle's whole
  content IS the value being fetched.**
- Both scenes are **live-path-only by construction**
  (`SimulatedShareService.rosterPhase` is `.loaded` from the first frame), so
  every simulated + DEBUG Share-tab capture is byte-identical.
  `ownerShareLoading` parks the §7.5.2 read in flight and never resolves it
  (`DebugHangingSharingEndpoint` — the MYR-326 / MYR-342 park-in-one-branch
  mechanism); `ownerShareUnreachable` fails EVERY per-vehicle read, which is the
  only route to the failure state since the service reports one only when all of
  them failed. **Capture each twice** — once normally, once with `xcrun simctl ui
  <udid> reduce_motion enabled` — to prove `MRTShimmerBand`'s fallback: the blocks
  stay, the sweep goes.

```sh
SIMCTL_CHILD_MRT_SCENE=ownerShareLoading xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=ownerShareUnreachable xcrun simctl launch <udid> app.myrobotaxi.ios
```

**THE SETTINGS HALF WAS WORSE THAN A FLASH** (MYR-392, the handoff above, now
closed) — scenes `ownerSettingsShareLoading` / `ownerSettingsShareUnreachable`.
MYR-386 recorded owner Settings as carrying "this exact flash on its own
surface". It was carrying something sharper: **`SettingsScreen` never called
`shareService.load()` at all.** Its only tasks were `pushPrefs.load()` and
`prepareAccountDeletion()`, and `ShareService.load()` had exactly two call sites,
both on `InvitesScreen`. So an owner who opened Settings without ever visiting
the Share tab sat on phase `.idle` with an empty array for the whole session and
read **"No one has access yet."** — a PERMANENT false claim about their own
account, on the page that also offers to REVOKE the access it had never read.

- **The fix is both halves, and they are one change.** Settings gets its own
  `.task { await shareService.load() }` plus MYR-386's vehicle-id re-ask (the
  §7.5.2 short-circuit on an empty fleet is per-vehicle here too, so without the
  re-ask the fix would reproduce the permanent-empty-hero it removes). Only then
  is it TRUE on this surface that "not asked yet" is "about to ask", which is
  what makes `.idle` shimmer with `.loading` legitimate here exactly as it is on
  the Share tab.
- **`SettingsScreen.SharedWithState` is the card's rule, and it deliberately does
  NOT call `ShareRosterState.resolve`.** That state models the Share tab's TWO
  sections; this card renders one thing — who can see the car right now — so it
  resolves from the ACCEPTED list alone and an account whose only rows are
  pending invites still reads the notice. Everything else is arm-for-arm the
  same, including **rows in hand outranking every phase** (this page performs the
  revoke whose re-read would otherwise blank it).
- **The failure arm is stricter than the empty one**: the service's sentence
  (`LiveShareService.unreadableMessage`, verbatim) and NO CTA at all. The "Invite
  someone" row would route to a Share tab failing the identical read.
- **The count badge was part of the same claim.** "0 people" over a shimmering
  card is the false statement in three characters, rendered from the same
  unfetched array; the badge now appears only with rows in hand or after a
  completed fetch (MYR-347 removed "VIEWERS · 0" for the sibling reason). A
  loaded-empty account still reads "0 people" exactly as before.
- **THE SKELETON MAY NOT WEAR THE REAL CARD'S FILL**, which is
  `ShareSkeletonCard`'s trap one screen over: `Color.mrtSkeletonFill` **IS**
  `surface` and `SettingsCard` fills with `.mrtSurface`, so `.regular` blocks
  inside the real card are invisible. `SettingsSharedWithSkeleton` takes
  `mrtSkeletonRowFill` through the REAL `.mrtSurface(.card, fill:)`, so radius,
  hairline and gutters are the loaded card's and only the fill differs. Its rows
  are `ViewerRow`-shaped (36pt avatar, 14/11pt lines, 12pt vertical padding) and
  the trailing Revoke pill's slot is left EMPTY — a control that exists
  regardless of the data must not be drawn as a block.
- **`ownerSettingsShareUnreachable` IS THE PROOF THAT THE SCREEN ASKS**, and that
  is why the failing arm earns a scene. `.idle` and `.loading` render the same
  skeleton, so a read parked in flight looks identical whether the screen asked
  or never did; only a read that FAILS can tell them apart. On the pre-fix screen
  it shimmers for ever — verified by reverting the `.task` on this branch, where
  `SettingsSharedWithUITests` and the mounted
  `testTheScreenAsksForTheRosterOnAppear` both fail and the rest stay green.
- Both scenes leave the Tesla Account section on the FIXTURE list (no
  `rendersLiveLinkedVehicles`), so the only thing in flight in either frame is
  the roster, and both are live-path-only by construction. Every simulated +
  DEBUG capture is unchanged: `ownerSettings`, `ownerSettingsTop`,
  `ownerSettingsLoading`, `ownerDeleteAccount` and the whole Share-tab family
  diff to zero pixels against `origin/main` outside the status bar, the
  "synced Ns ago" stamp and the home indicator — the three bands a base-vs-base
  control moves in too.

```sh
SIMCTL_CHILD_MRT_SCENE=ownerSettingsShareLoading xcrun simctl launch <udid> app.myrobotaxi.ios
SIMCTL_CHILD_MRT_SCENE=ownerSettingsShareUnreachable xcrun simctl launch <udid> app.myrobotaxi.ios
```

**Found and NOT fixed here** (MYR-392): `TeslaAccountRowSkeleton` renders its
SECOND bar — the "model · plate" line — at `.regular` emphasis INSIDE the real
`SettingsCard`, i.e. `mrtSkeletonFill` on `mrtSurface`, which is the invisible
-on-card trap this very file documents. `ownerSettingsLoading` therefore shows
two lonely name bars with no detail lines. It is MYR-326's scene and byte-stable,
so changing it is a deliberate capture change and belongs to its own issue.

**The Live Activity is the first surface this app does not draw** (MYR-172) —
scene `riderLiveActivity`. The rider's ride card on the lock screen and in the
Dynamic Island is rendered by a SEPARATE PROCESS, the new `MyRoboTaxiWidgets`
app-extension target (`app.myrobotaxi.ios.widgets`), so booting a screen and
screenshotting it captures nothing at all — the scene starts a REAL Activity
through the shipping `SystemRideActivityPresenter` and the picture is of the
system.

- **The content state is a MIRROR of a generated type, and mirrors are the
  MYR-362 shape.** `ActivityAttributes.ContentState` requires `Hashable` and the
  generated `LiveActivityContentState` is only `Codable, Equatable, Sendable`, so
  a hand-kept copy is unavoidable. The property NAMES are the wire keys —
  ActivityKit decodes `aps.content-state` with a plain `JSONDecoder` and no key
  strategy — so there are no `CodingKeys` and adding one is breaking while still
  compiling. `eta` is the silent one: optional on the wire AND optional here, so a
  wrong key decodes to `nil`, which is indistinguishable from the server's own
  legitimate "ETA unknown, key omitted". No throw, no log, just a lock screen that
  never counts down. The guard is `RideActivityContentStateTests`, which asserts
  this type's RAW KEYS against the GENERATED type's raw keys — the check MYR-362
  did not have. `LiveActivityRideStatus` is used DIRECTLY (it is `Hashable`) so the
  `unrecognized` arm the schema mandates comes for free.
- **`eta` is an ABSOLUTE unix-SECONDS instant, and that is what makes the
  countdown honest.** A duration decays silently on a screen the server cannot
  repaint; an instant stays true however late it is read, so `Text(timerInterval:)`
  runs the countdown on the phone between the 60–90s pushes. The client therefore
  NEVER computes one: a locally-started Activity opens with no countdown and gains
  one when the first push lands, because the contract's ETA is the CAR'S OWN nav
  ETA and `destination.minutes` is not it.
- **CANCELLED IS AN ERASURE, NOT A STATUS.** `LiveRideRequestService.integrate`
  maps the wire's `cancelled` to no app status at all and sets `activeRequest` to
  `nil`, so the only signal the client gets that the ride is over is the record
  DISAPPEARING. `RideActivityPhase.live` therefore carries the LAST CONTENT STATE:
  at the moment a final frame is most needed there is no record left to build one
  from. `RootView` observes the WHOLE record rather than `activeRequest?.status`
  for the same reason — a status-only observer sees `nil == nil` and never fires.
- **A 409 on token registration is an INSTRUCTION, not an error** (§7.21): the ride
  is already terminal, so the Activity will never be pushed to, and the client is
  the only thing that can still take it off the lock screen. It ends immediately
  and does NOT guess which terminal state it reached — writing "You've arrived"
  over a cancelled ride is worse than a card that goes away.
- **Two capture traps, both found BY capturing rather than by reading.**
  (1) `simctl terminate` does NOT end an app's Live Activities — that is the whole
  point of the feature — so the second `MRT_ACTIVITY_STATE` run silently
  photographs the FIRST run's Activity. The give-away was an `arrived` capture
  (which carries no ETA at all) rendering a live countdown; `RideActivityDebugLauncher`
  now sweeps `Activity.activities` before starting. (2) A stale-date already in the
  PAST at `request` time is ignored or clamped, so the frame is never born stale.
- **The STALE presentation has no headless capture route, and is not claimed as
  one.** With a short future stale-date the system does mark the Activity
  `state: stale` (visible in `log show --predicate 'subsystem ==
  "com.apple.activitykit"'`), but the compact Dynamic Island kept rendering the
  confident countdown, and iOS then DISCARDS a stale ephemeral Activity within
  ~60s ("Ephemeral activity ended… no longer relevant"). The LOCK-SCREEN card has
  no route at all: `simctl` has no lock command. Both need a device or a human at
  the Simulator's Device menu.

```sh
SIMCTL_CHILD_MRT_SCENE=riderLiveActivity xcrun simctl launch <udid> app.myrobotaxi.ios
# then background the app so the island shows it, and screenshot the SYSTEM:
xcrun simctl launch <udid> com.apple.Preferences && xcrun simctl io <udid> screenshot di.png
# MRT_ACTIVITY_STATE=enroute|accepted|arrived|completed|stale (default enroute)
```

**TWO BANNERS FOR ONE RIDE, AND THE ONE THE SERVER PUSHED TO WAS NOT THE ONE
STARVING** (MYR-405, client defect, build `202607312110`) — probe
`MRT_ACTIVITY_ORPHAN=seed|relaunch`. TestFlight, Jul 31: two simultaneous Live
Activity cards for one completed ride — an orphan stuck on "IN RIDE · On the
way · **Not updating**" beside a second card that had received "DROPPED OFF" —
and a Dynamic Island still reading "In ride" long after the ride ended.

**THE HYPOTHESIS WAS HALF RIGHT, AND THE OTHER HALF IS WORSE.** The issue
predicted a race with ActivityKit's ASYNCHRONOUS restore of `Activity.activities`
— the start path enumerating an empty list mid-restore and requesting a second
card. That race is real and had bitten the CAPTURE tooling the same day
(`RideActivityDebugLauncher`'s sweep, MYR-398). But **production never enumerated
`Activity.activities` at all.** `SystemRideActivityPresenter.start`'s "never run
two" guard is `activity == nil` — THIS PROCESS's instance variable, which is nil
in every new process — so the duplicate is not a race the app sometimes loses. It
is **deterministic on every relaunch into a live ride**. Measured, two processes,
one ride: pre-fix `count=2 [ride/active, ride/active]`, fixed `count=1` with the
coordinator's phase on the restored card. A guard on a process-local handle is not
a guard on a lock screen that outlives the process.

- **`Activity.activities` IS THE ONLY WAY TO SEE THE PREVIOUS PROCESS'S CARD, AND
  IT SETTLES LATE.** `RideActivityPresenting` grows a plain synchronous
  `presentedActivities` read and the WAITING is policy in the coordinator
  (`RideActivityRestore`, ~2s in 250ms steps), so a stub can drive the
  half-restored list a real ActivityKit never will. **An empty list is never
  believed until the budget is spent**; a non-empty one is believed once it stops
  changing. The wait is latched per process (`restoreSettled`) — the race is a
  once-per-process phenomenon and a ride accepted while the app is open must not
  sit two seconds behind its own card.
- **ADOPT, NEVER DUPLICATE.** An Activity for the SAME ride is taken over
  (`adopt(rideID:)`) and `registered` is cleared so ITS token is re-registered.
  That clearing is the half that makes the kept banner live again: the server keys
  one token per `(ride, rider)` and replaces it destructively, so until it hears
  the adopted Activity's own token every push still addresses whatever this account
  registered last — which, in the client's case, was the duplicate.
- **ORPHAN REAPING generalizes §7.21's 409-means-end-now** to launch AND
  foreground. Any on-screen Activity that is not the account's live ride ends
  `.immediate`, and the server is told. **Two skips carry as much weight as the
  reap**: `.ended` is left alone (it is living out its dismissal policy, including
  this issue's own five minutes — reaping it would be the fix cancelling the fix),
  and `.dismissed` is remembered rather than reaped.
- **⚠️ THE REAPER'S INPUT IS THE DANGEROUS PART, AND IT NEEDED A THIRD ARM.**
  `activeRequest == nil` is BOTH "this rider holds no ride" and "§7.8 has not
  answered yet", and reaping on the second reading would take a live ride's card
  off the lock screen every time the phone launched with no signal — MYR-326's
  "loading ≠ unavailable" and MYR-343's "three situations, one boolean", with a
  lock-screen card as the casualty. `RideActivityLiveRide.unresolved` reaps nothing
  and adopts nothing, and `RideRequestService.hasResolvedActiveRide` is the fact
  behind it: set only where a §7.8 read genuinely ANSWERED, never reset, and
  defaulted `true` for the simulated service. ONE bounded budget polls the
  Activity list and the ride pipeline together, because both settle at launch.
- **ADOPT BEFORE REAP, and `endActivity` skips the HELD Activity.** Two cards can
  carry the SAME ride id — that is the client's screenshot — so a reap keyed on the
  id alone takes down the banner the adoption just kept. The adoption is what marks
  which of two identically-named cards survives. The same rule spares the §7.21
  DELETE (`isDuplicateOfAdopted`): the registration is keyed on the ride, so
  deleting it for a duplicate would starve the survivor **from inside the fix**.
  Both were found by a test, not by reading.
- **COMPLETED LINGER = 5 MINUTES**, client decision, superseding MYR-194's ~15.
  It is a CLIENT-SIDE END POLICY and is **not** the server's 24h-floored APNs
  expiration (MYR-398 review) — that governs how long APNs keeps TRYING to deliver;
  this governs how long a finished ride stays on the lock screen. **The server
  still disagrees**: `activity_notifier.go`'s `terminalStatuses` sends its own
  `event: end` with `dismissal-date = now + 15min` for `completed`, and whichever
  instruction lands last wins. Server follow-up, not fixable here.
- **A NEW RIDE ENDS EVERY PRIOR CARD**, and that is the same expression as the
  duplicate heal rather than a second rule: for a genuinely new ride the plan
  adopts nothing, so every prior Activity is in `reap`.
- **THE RIDER'S SWIPE IS FINAL.** A dismissal is otherwise INVISIBLE — no callback,
  no error, and `Activity.activities` keeps listing it — so the held Activity's
  `activityStateUpdates` is consumed and `.dismissed` is recorded. It is an INPUT
  to the state machine (`dismissedRideIDs`) rather than a phase case, deliberately:
  it outlives the phase, it can arrive from the RESTORE list for a ride this
  process never presented, and more than one ride can be in it. A dismissal is a
  decision about ONE ride — a NEW ride starts normally, which is the client's "or
  if new ride begins" — and the server is told to stop pushing to a card nobody can
  see. The in-app tracking sheet carries the ride either way.
- **THE REPRO IS TWO PROCESSES OR IT IS NOTHING.** The defect lives on a process
  boundary, so no unit test and no single launch can produce it. `seed` starts a
  card and force-quits (`simctl terminate` does NOT end Live Activities — that is
  the whole point of the feature); `relaunch` runs the PRODUCTION coordinator over
  the PRODUCTION presenter for the same ride and logs a census through `os_log`
  (`--console` does not reliably carry a SwiftUI app's stdout; `log stream` is what
  the MYR-222 camera probe already uses).

```sh
SIMCTL_CHILD_MRT_ACTIVITY_ORPHAN=seed xcrun simctl launch <udid> app.myrobotaxi.ios
xcrun simctl terminate <udid> app.myrobotaxi.ios      # the card SURVIVES this
SIMCTL_CHILD_MRT_ACTIVITY_ORPHAN=relaunch xcrun simctl launch <udid> app.myrobotaxi.ios
xcrun simctl spawn <udid> log stream --level=info \
  --predicate 'subsystem == "app.myrobotaxi.ios" AND category == "liveactivity"'
# healthy: count=1 throughout, and one `coordinator phase=<rideID>` line.
# Uninstall between runs — a Live Activity outlives the app, so a stale one
# silently makes the next run a picture of the last.
```

**Invite links have an address** (MYR-346) — an invite is shared as
`https://myrobotaxi.app/join/{CODE}`, a branded web page whose OG card renders in
the thread and which, on a phone that has the app, opens it straight to the
prefilled code. MYR-340 made the share message a mini-onboarding; this gives the
six characters somewhere to point.

- **Entitlement**: `com.apple.developer.associated-domains: [applinks:myrobotaxi.app]`,
  declared in `project.yml` under the target's `entitlements.properties` — the
  same XcodeGen mechanism as `aps-environment` and the SIWA entitlement, so
  `App/MyRoboTaxi.entitlements` stays generated and is never hand-edited. Unlike
  `aps-environment` it needs no dev/prod split: `applinks:` has no such axis, and
  the development-vs-production distinction lives in how iOS FETCHES the AASA
  (Settings ▸ Developer ▸ Associated Domains Development bypasses Apple's CDN).
  **THREE things must agree** or the link silently opens Safari with no error
  anywhere: the entitlement, the AASA served at
  `https://myrobotaxi.app/.well-known/apple-app-site-association` (appID
  `NFKX777598.app.myrobotaxi.ios`, components `/join/*`), and the provisioning
  profile. `InviteLink.host` is the client's single source of truth for the first
  two, and `InviteLinkHostTests` pins it.
- **The parse is strict about the envelope, forgiving about the code**
  (`App/Sources/Links/InviteLinkRouting.swift`, pure): https + exactly our host +
  exactly `/join/{one segment}`, then upper-case and strip to `[A-Z0-9]` and
  require **exactly 6**. A wrong length is REFUSED, not truncated — that length
  check is what makes auto-submit safe, since a malformed link must never spend
  one of the rider's 10 redeem attempts per minute (§7.5.5). **An unrecognised
  link is not an error**: it resolves to `.ignore` and the app opens normally,
  because rendering a URL this build does not know is the web's job.
- **Routing matrix** (`InviteLinkRouting.route`, a pure function of
  `InviteLinkContext { screen, isBusy }`). The context takes the SCREEN as the
  signed-in fact, deliberately — `session.isSignedIn` is `false` in SIM until the
  tap and `false` in every DEBUG scene, all of which boot into a signed-in shell,
  so the screen is the only fact true on every path (the same choice
  `applyPushTapRoute` already makes). Signed in on `ownerHome`/`sharedHome`/
  `emptyState`/`inviteCode` → present `InviteCodeFlow` prefilled, which
  auto-submits. `signIn`/`resolvingSession` → `.awaitSignIn`. Mid-ride, or on
  `modeChooser`/`addTesla`/either tutorial → `.awaitIdle`.
- **A link never stomps work, and is never dropped.** Push (MYR-186) DROPS a tap
  that lands at the wrong moment because its cold-launch refetch reaches the same
  surface anyway; **an invite code has no refetch** — nothing in the system will
  ever produce those six characters again — so `RootView` HOLDS it in
  `pendingInviteCode` and re-asks on `.onChange(of: inviteLinkContext)`. Every
  deferral state resolves on its own, so a held code always lands. Cancelling a
  link-opened flow restores the exact shell it interrupted (`InviteLinkReturn`);
  completing goes to the rider Live Map, where the car they just joined is. A link
  arriving on the first-run choice screen uses the EXISTING `.onboarding` origin,
  so it is byte-identical to tapping "Join with an invite code" there.
- **Delivery is a MAILBOX, not a closure** (`InviteLinkBridge`). A cold-launch
  activation is delivered during launch, before `RootView` exists; the mailbox
  holds it and `install` drains it. BOTH delivery paths feed it — SwiftUI's
  `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` and the app delegate's
  `application(_:continue:restorationHandler:)` — because this app is
  SwiftUI-lifecycle WITH a `@UIApplicationDelegateAdaptor`, exactly the
  configuration where which callback fires is not ours to predict. Re-delivery is
  a genuine no-op: it resolves to the same route, and `InviteCodeFlow.prefill`
  assigns `code` without firing `onChange` when the value is unchanged.
- **`InviteCodeFlow`'s only external entry point is `prefilledCode`**, which
  assigns `code` and lets the EXISTING `onChange` clean, clamp and auto-submit —
  so a link redeems by exactly the path a thumb does, and the shake, the rate-limit
  line and the "you already have access" line are all the shipping ones. Nothing
  about the cell input or `submit` is reachable from outside (kept deliberately
  narrow so MYR-344's work inside those internals merges cleanly). Its `.task` is
  now `.task(id: prefilledCode)` so a SECOND link re-prefills a flow already up;
  with no link the id is `nil` and it runs once on appear exactly as before.
- **The owner tapping their own link is the likeliest first use of this feature**
  and needed no new code: §7.5.5 answers `409`, the Kit folds it to
  `.alreadyHasAccess`, and the entry screen already renders that honestly —
  "You already have access to that Tesla", entry left intact, no shake.
- **The share payload is the link and nothing else** (superseded by MYR-359, and
  the link itself by MYR-368 — see "The share payload is ONE LINK" above).
  MYR-346 led the message with the join link on the reading that platforms
  preview the FIRST link; iMessage actually requires the message to be nothing
  BUT a link, so the steps, the TestFlight link and the bare code line are gone
  from the payload and live on the landing page instead. The link carries
  `?from={Name}`, which `code(from:)` ignores by design — and from MYR-368 it is
  MINTED AND SIGNED BY THE SERVER (`ShareInvite.shareUrl`, contracts 0.22.0),
  carrying `k` plus `from` AND `to`, all three covered by one Ed25519 signature.
  This client composes the link only as the documented fallback for a pre-0.22.0
  server; `code(from:)` ignoring the query is what makes both grammars work.
- **End-to-end cannot be verified until the web AASA deploys** — until then
  `simctl openurl` opens Safari, not the app. The routing is pinned by
  `App/Tests/InviteLinkRoutingTests.swift`; to drive the real screens use the
  DEBUG hook **`MRT_JOIN_LINK`** (a full URL or a bare code; `-MRT_JOIN_LINK
  <value>` arg fallback), which posts to the mailbox from `RootView.init` — i.e.
  in the same before-the-view-exists window a real activation lands in, so it
  exercises the held-then-drained path rather than a shortcut around it:

  ```sh
  SIMCTL_CHILD_MRT_SCENE=ownerHome SIMCTL_CHILD_MRT_JOIN_LINK=RBO246 \
    xcrun simctl launch <udid> app.myrobotaxi.ios          # signed in → prefilled + submitted
  SIMCTL_CHILD_MRT_JOIN_LINK=https://myrobotaxi.app/join/RBO246 \
    xcrun simctl launch <udid> app.myrobotaxi.ios          # cold + signed out → held silently
  ```

  Unset — which it is for every scene and capture — nothing reads it and no scene
  changes by a pixel.

**Route-availability capture modifier** (MYR-395, DEBUG-only, orthogonal to the scene): `MRT_ROUTE_UNAVAILABLE=1` (env or `-MRT_ROUTE_UNAVAILABLE 1`) swaps the rider's route provider for `StraightLineRideRouteProvider`, i.e. exactly the `[from, to]` pair `AppleRideRouteProvider` returns when MKDirections is throttled, offline or loses its 8s deadline. Everything downstream is the shipping store, predicate and presentation, so the capture is the real degradation rather than a hand-set state. Applies to any route surface — `reviewLongDistance`, `review`, `booking`, `searchSelected`. Unset, every scene runs the real Apple provider and is byte-identical.

**Owner-sheet capture modifiers** (DEBUG-only, orthogonal to the scene): `MRT_OWNER_DETENT=half|tall` boots at the controls detent or (MYR-332) at the TALL one — MYR-319 makes it apply on the LIVE fleet too, not just the simulated/injected ones; `MRT_OWNER_VEHICLE=<n>` selects a fleet row; `MRT_OWNER_SCROLL=bottom|<0…1>` (MYR-319) overrides where the dense sheet's scroll rests, so a section can be framed on a scene that carries no per-scene anchor. The last two exist because the ONLY way to see the controls stack fed by a REAL REST snapshot is `MRT_SCENE=ownerHome MRT_TELEMETRY=live MRT_BACKEND_URL=…`, and headless tooling can neither drag nor scroll the sheet. Unset, every existing scene's detent and anchor are exactly as before.

### Streaming-fix camera probe (MYR-222)

Devices STREAM GPS fixes (~1Hz) — a static simulated fix can NEVER catch a
camera feedback loop (four MYR-213…217 rounds passed static probes; the
streaming loop shipped anyway). Any camera/follow/pin-drop change MUST be
probed under a moving fix:

```sh
xcrun simctl privacy <udid> grant location app.myrobotaxi.ios
xcrun simctl location <udid> start --speed=15 --interval=1 \
  37.7871,-122.3971 37.7920,-122.3999 37.7960,-122.4040 37.7990,-122.4090
xcrun simctl spawn <udid> log stream --level=info \
  --predicate 'subsystem == "app.myrobotaxi.ios" AND category == "camera"' &
xcrun simctl launch <udid> app.myrobotaxi.ios -MRT_TELEMETRY live -MRT_SCENE pinDropRealPath
```

Every programmatic camera write and settle classification is logged (DEBUG
only, `VehicleMapView.mrtCameraTrace`). Healthy pin-drop: ONE bounded seating
burst (`WRITE owner` ≤4), then `fixChanged … phase=settled` with NO further
writes at any fix rate; healthy idle: `WRITE recenter` per fix only until a
gesture logs `follow off`, then zero. Repeating write/settle pairs per fix =
the MYR-222 loop class. Probe idle the same way with `-MRT_SCENE idle`.
`simctl location clear` when done (leftover streams corrupt the static
drift-gate scenes).
