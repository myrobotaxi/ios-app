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

- Rider request flow: `idle`, `search`, `searchFiltered`, `searchSelected` (destination chosen, "Continue" CTA), `pinDrop`, `pinDropRealPath` (MYR-217: boots to idle, then auto-drives the REAL idle→search→Continue→pinDrop transition with live updates flowing — use this, not cold `pinDrop`, to probe pin-drop entry camera behavior), `review`, `reviewPicker`, `booking`, `pending` (minimized "Request sent" pill), `trackingLeg1` (to pickup), `trackingLeg2` (in-ride), `trackingArriving`, `summary`, `declined`, `riderBusyVehicle` (MYR-233: the Review sheet with an UNAVAILABLE vehicle — muted Busy chip on the fleet row, gold instant CTA replaced by "Schedule with … instead". Select the state with `MRT_BUSY_REASON=busy|inService|offline|paused`, default `busy`; each is built from real wire inputs through `LiveFleetMemberMapping`, so the capture exercises the shipping predicate. **MYR-342 adds `paused`** — the owner's ride-share switch off (`rideShareEnabled: false`) on a car that is otherwise PARKED and healthy, which is the whole point of the state. It is the one reason whose CTA area holds **no button at all**: the muted "Paused" chip and the helper line "{Owner} has paused ride requests right now", and nothing else. The other three keep MYR-233's "Schedule with … instead" route because each ENDS on its own; an owner's pause is open-ended and the server refuses scheduled rides against it too, so offering scheduling would be a `409 vehicle_unavailable` with extra steps), `riderPlateChip` (MYR-286: the Booking sheet's plate chip carrying the REAL owner-entered plate instead of the `VIN ····xxxx` degrade — same live-shaped `VehicleSummary` path, with `licensePlate` set), `riderScheduleFloored` (MYR-316: the Schedule slide-up card with the SERVICE-WINDOW FLOOR applied — a muted "Lunar is in service until Sat, Aug 1 · 2:00 PM" caption, dimmed-but-visible day/time chips for every slot before the car is back, and a selection already pulled forward to the first bookable one. Injects a live-shaped in-service `VehicleSummary` carrying `serviceEstimatedEndAt` through the REAL `LiveFleetMemberMapping`, then opens the card via the existing one-shot `opensScheduleOnSearch` hook, so the capture exercises the shipping `RideScheduleFloor` grid rule rather than a hand-set flag. **A vehicle with NO window imposes NO floor** — that is the common case and every other rider scene is byte-identical).
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

- Rider scheduled-ride sheet: `scheduledDetails`, `scheduledReschedule`, `scheduledRequested`, `scheduledConfirmCancel`.
- Owner side: `ownerHome`, `ownerDrives` (Drives tab, `initialOwnerTab` "drives"), `ownerIncoming`, `ownerIncomingQueued` (MYR-317: the SAME incoming card with the queue badge up — a muted "+2 more waiting" chip trailing the "INCOMING RIDE REQUEST" kicker, the owner's only signal that resolving this card is not the end of the queue. The simulated service has no incoming FEED, so the count comes from its DEBUG-only `debugSeedWaitingIncoming`; the live service derives the identical number from the held incoming page. Everything else is `ownerIncoming` verbatim, so the pair is a clean before/after of exactly the chip — `ownerIncoming` itself stays pixel-identical), `ownerScheduled`, `ownerScheduledLive` (MYR-312/313: the SCHEDULED incoming card on the **live** branch, in the client's condition — Saturday 5:30 PM reservation, target car IN SERVICE now. The only scene that forces `HomeScreen`'s live rendering (`DebugScene.rendersLiveIncomingRequest`), because the real requester name and the scheduled accept-gate exemption are both live-only branches a sim capture can't reach; it injects an in-service `DebugVehicleDetailsFleet` the seeded record targets by id, so the real fleet join + the real `isAcceptGated` predicate both run. `ownerScheduled` stays simulated and pixel-identical), `ownerVehicleEnriched` (MYR-320: the vehicle-details section with every enrichment field populated off ONE live-shaped snapshot — Model "2026 Model Y Performance" composed from the display-ready `trimLabel` while the snapshot ALSO carries the raw `trim` badge "p74d" it must NOT substitute, Color "Quicksilver" flowing through the EXISTING `VehicleState.color` with no mapping change, and an "FSD" row reading "FSD (Supervised) v14.3.5" verbatim directly after Software. `ownerVehicleDetails` keeps the pre-enrichment shape — blank color, no FSD row — so the pair is a clean before/after. Pair with `MRT_OWNER_DETENT=half`), `ownerServiceWindowManual` (MYR-320: the same in-service car as `ownerServiceWindow`, with the renamed "Service completion date" row carrying its manual sub-caption "Set manually — Tesla hasn’t provided an estimate for this visit". That caption is only reachable after a save whose echo matched the owner’s submission — proof Tesla held no estimate — which headless tooling cannot perform, so the scene seeds the provenance THROUGH the shipping `LiveVehicleCommandExecutor.provenance` classifier. The wire carries NO source discriminator, so a cold read renders no caption at all), `ownerVehiclePlate` (MYR-286: the Vehicle details section with a real owner-entered plate on BOTH read surfaces — pair with `MRT_OWNER_DETENT=half`; the same scene without a plate is `ownerVehicleDetails`, which now shows the "Add plate" affordance rather than an uneditable VIN), `ownerServiceWindowSaved` (MYR-316, client defect: the owner saved a completion date, the server persisted it, and the sheet kept showing the old state. The same in-service car whose snapshot carries **NO** window — the state the sheet is in when the editor opens — with the production `LiveVehicleCommandExecutor.setServiceWindow` run against `DebugServiceWindowEndpoint` on boot and **nothing refetching the snapshot afterwards** (the field is snapshot-only by contract). Everything the capture shows about the window therefore came from the write ECHO, through the unified `VehicleServiceWindow.resolvedEndAt`; before the fix both read surfaces took the still-empty snapshot and this scene rendered no line and no time at all. Capture at PEEK for the hero line, pair with `MRT_OWNER_DETENT=half` for the row), `ownerNoticeRejected` (MYR-301, client defect: "The car didn’t accept that" stuck forever. A real 502 `command_failed` on `auto_conditioning_stop` settles the real `.rejected` notice, which now clears itself after `LiveVehicleCommandExecutor.defaultNoticeDisplayDuration` (6s) — so capture at t≈2s and t≈8s, the same two-shot pattern `ownerDispatchedCompleted` uses. **That bounded display applies to `ownerNoticeCharge`/`ownerNoticeAsleep`/`ownerNoticeSeat` too**: take their captures inside the window. Pair with `MRT_OWNER_DETENT=half`), `ownerNoticeRejectedInService` (MYR-329, client defect: the SAME rejection with the reason NAMED. Jul 28: "Any reason why car didn't accept climate, is it because low battery?" — the car was in service mode and the battery was fine, but `ownerNoticeRejected`'s generic "The car didn't accept that" left a wrong guess as the only guess available. Same 502 `command_failed` on `auto_conditioning_stop`, same real `LiveVehicleCommandExecutor`, same real `.rejected` settle — the ONE difference is that the wire error carries the server's canonical token in `message` (`"vehicle command failed: vehicle_in_service"`, rest-api.md §7.9), so the shipping `RestError.commandRejectionReason` parse runs and the row reads "Car is in service — commands are limited". Nothing about the notice is hand-set. The tile sub stays "Declined" for every reason — the reason lives on the full-width row, which has the space to say it properly. It needs its own scene because `ownerNoticeRejected` is MYR-301's lifecycle capture and stays byte-identical, and because this state has no other capture route at all: it takes a car genuinely sitting in service mode, behind a real auth session, refusing a real command. The pair is a clean before/after of exactly that one line. Same TWO-SHOT bounded display — t≈2s and t≈8s. Pair with `MRT_OWNER_DETENT=half`), `ownerVehicleSeatsHeatOnly` (MYR-308: the seat section for a car whose REST SPEC says it has NO cooled seats — `DebugVehicleDetailsFleet(ventedSeatReadBacks: true, seatCoolingCapable: false)` carries BOTH the cooler read-backs that make the MYR-299 presence heuristic fire AND the contracts-0.16.0 `seatCoolingCapable: false` that authoritatively overrules it, so the capture is the precedence proof: "SEAT HEATING", flame-only rows, and no Heat↔Cool toggle at all — not even a greyed-out one, which would imply hardware the car lacks. Pair with `MRT_OWNER_DETENT=half`), `ownerMediaNowPlaying` (MYR-303: the Media card with a REAL now-playing block off the wire — title/artist/album/source plus a real duration + sane elapsed, mapped by the production `VehicleContractMapping.nowPlaying` and reconciled by the real `LiveVehicleCommandExecutor`. Shows the shipping render: the prototype media card's title/artist grammar, a PASSIVE progress line (no thumb — §7.9 has no seek-to-position), no invented cover art (the wire carries no artwork), and a live transport row whose icon is the car's own `Playing`), `ownerMediaNoSession` (MYR-314: the same card with NO media session — the car cleared the title to `""` and reports no `mediaPlaybackStatus`. Both halves of one real situation: the honest idle line instead of the track that just ended, and the muted, non-interactive transport row with "Start media in the car first". Pair both media scenes with `MRT_OWNER_DETENT=half`), `ownerFreshnessStale` / `ownerFreshnessWaking` (MYR-315: the owner sheet's tappable **freshness stamp**, which is **LIVE-ONLY** — the prototype has no recency element in the sheet hero at all, and a simulated snapshot carries no `isStreaming`/`lastUpdated` to be honest with, so on the simulated path the stamp is never constructed and every other owner scene stays byte-identical. Both scenes inject `DebugFreshnessFleet` — a car OFFLINE for 7h whose live-shaped `VehicleState` travels the production `VehicleContractMapping`, so the stamp shown is the one the shipping resolver produced — and force `HomeScreen`'s live branch via `DebugScene.rendersLiveVehicleFreshness`. `ownerFreshnessStale` is the resting "Synced 7h ago"; `ownerFreshnessWaking` is the in-flight "Waking Lunar…", seeded as a phase (`initialRefreshPhase`) because headless capture tooling can't synthesize the tap. Capture at PEEK — where the stamp matters most, since the tile qualifiers + "Not live" footer only exist at half, below a scroll — or pair with `MRT_OWNER_DETENT=half`), `ownerFreshnessInService` / `ownerFreshnessRefused` (MYR-345, the client's own screenshot AKXUQLSW…: the SAME in-service fleet `ownerServiceWindow` injects — so that scene stays byte-identical — with the stamp's live rendering forced on, so the peek hero carries BOTH live-only qualifier lines at once. No scene reached that pair before, and it is the only variant where the flat 24pt reserve was visibly wrong. It is also the DEAD-TAP repro: a car read "just now" is already current, so the tap resolves to the acknowledgement — the branch that rendered NO copy at all until this issue. `ownerFreshnessRefused` is the same car read 7h ago, whose §7.15 call the server refuses BY NAME (`502 command_failed` + MYR-329's `vehicle_in_service` token, held 1.5s so the in-flight phase is a real state); capture at t≈1s for "Waking Model Y…" and t≈4s for the named settle. **A refusal the server explained must be explained to the owner** — silence is the bug even when the refusal is correct), `ownerServiceWindow` / `ownerServiceWindowEditor` (MYR-316: the owner's side of the service window, injected as `DebugVehicleDetailsFleet(status: .inService, serviceEstimatedEndAt: <next Sat 2 PM>)` — the instant rides BOTH read surfaces (live-shaped snapshot AND list row) exactly as a real server emits it and travels the production `VehicleContractMapping` folds. `ownerServiceWindow` is the READ: the In Service badge with a muted "Service Estimated Completion · Sat, Aug 1 · 2:00 PM" directly beneath it, best captured at PEEK where the line lives; pair with `MRT_OWNER_DETENT=half` to also see the Status & location card's matching In Service chip + the "Expected back" row. `ownerServiceWindowEditor` is the WRITE: the same car with the entry sheet already presented, seeded via `DebugScene.opensServiceWindowEditor` because the row lives inside a half-detent scroll that headless tooling cannot tap — the same stand-in-for-a-tap precedent as `ownerFreshnessWaking`. Its Save runs the production `LiveVehicleCommandExecutor.setServiceWindow` against `DebugServiceWindowEndpoint`, which reproduces the two server behaviours that shape the client: future-only validation, and **Tesla precedence** — the echo is Tesla's `service_etc` when one exists, NOT the owner's submission, which is why the executor adopts the echo. Both scenes leave every other owner scene byte-identical: a car that is not in service renders no line and no row), `ownerRideShareOn` / `ownerRideSharePaused` / `ownerRideSharePending` (MYR-342: the owner's **ride-sharing toggle**, the last row of the Status & location card — `MRTToggle` (gold-on) with a state caption beneath it, "Riders can request this car" / "Paused — ride requests are off". All three inject a live-shaped `rideShareEnabled` on BOTH read surfaces and force `HomeScreen`'s live branch via `DebugScene.rendersLiveRideShareToggle`, because the row is **gated on the live path on purpose**: a switch that cannot reach `PUT /api/tesla/vehicles/{id}/ride-share` (rest-api.md §7.18) would appear to withdraw the owner's car from ride-hailing and do nothing at all. That gate IS the feature, so a capture goes through it rather than around it — which is also why every other owner scene is byte-identical and the card grows its one new row only here. `ownerRideSharePending` is the write IN FLIGHT and has no other capture route: against a real backend it lasts milliseconds, so the scene parks the write inside a stub that never answers (`DebugHangingRideShareEndpoint`) and performs the flip on boot through the SHIPPING `setRideShareEnabled` — the spinner is the real `uiState(for: .rideShare).isPending`, and the caption already reads "Paused" because the flip is OPTIMISTIC. Pair all three with `MRT_OWNER_DETENT=half`), `ownerDispatchedCompleted` (MYR-292: owner Home holding a `completed` ride — boots with the "Dropped off ✓" banner UP; the 5s auto-dismiss then acknowledges the ride on `OwnerHomeState`, so capture at t≈2s and t≈8s to get both halves. The acknowledgement is owner-scoped state, NOT `HomeScreen` @State, so it survives the tab switch that used to bring the banner back).

- Vehicle sharing (MYR-184): `ownerShare` (the owner Share tab on the SIMULATED path — the prototype's own render: an email field, three fixture viewers with their presence dots, a pending row captioned with an email address. The BEFORE half of the pair and this screen's drift-gate anchor; it must stay byte-identical forever), `ownerShareLive` (the SAME tab against rest-api.md §7.5. Four differences, all of them the contract asserting itself: the pending caption names the **CODE** — "Code RBO246 · sent 2d ago" — because §7.5 has no email anywhere; that row carries the **TIER** the owner chose, which the prototype's `doSend` discarded outright; the accepted viewer's presence dot is **OFF**, since v1 ships no presence signal and the row must not claim someone is watching; and ONE pending row stands for a MULTI-VEHICLE invite — two server rows sharing one code — which is the §7.5.1 regrouping running for real), `riderSharedEmpty` (the rider Live Map with ZERO shared vehicles — a state that could not exist before this issue, because `SharedViewerState.vehicle` defaulted to `VehicleFixtures.vehicles[0]` with NO live gate, so a signed-in rider who had redeemed nothing watched a map captioned "Cybercab", a car on nobody's account, ticking fixture telemetry. The honest render has no map at all), `riderWatchOnly` (§7.5.0 — the rider idle sheet for a viewer BELOW the `rides` tier: the gold "Where to?" search bar is replaced by a muted "You can watch {car}" line, because the server will 403 a ride create from this tier and the client must not offer what will fail), `riderInviteRateLimited` (§7.5.5 — the invite-code screen refusing on the RATE LIMIT. Deliberately NOT the shake: nothing is wrong with the code, and clearing + shaking would say "wrong code" and send the rider off to ask for a new one. The entry stays and a quiet line says to wait), `riderInviteJoined` (the invite success screen built from a REAL `RedeemShareInviteResponse`. It used to hardcode `InviteHostFixture` — "Alex's Model Y · Roommate", a person and a car that exist nowhere. On a MULTI-VEHICLE invite, so the "+1 more vehicle" line is in frame, and with the capability line reflecting the ACTUAL tier instead of promising rides unconditionally).

  All six are **live-path-only and unreachable from a simulated capture by construction**: `SimulatedShareService` mints no code (so no share sheet, no code caption, no tier line) and `SimulatedSharedVehicleCatalog` always holds three `rides`-tier grants with a redeem that cannot fail (onboarding.jsx:421's forgiving check). They inject `DebugShareEndpoint` and run the **production** `LiveShareService` / `LiveSharedVehicleCatalog` against it — the same "real code path, injected wire" precedent as `DebugServiceWindowEndpoint` — so what the capture shows came from the shipping grouping, tier mapping and gates, not a hand-set flag. The two invite-code scenes also set `autoSubmitsSampleCode`, because headless tooling cannot type six characters into the hidden field (the same stand-in-for-a-tap precedent as `ownerFreshnessWaking`). Nothing consults these overrides unless the scene is one of the six, so every existing scene is byte-identical.

  **The share MESSAGE is a mini-onboarding** (MYR-340) — scenes
  `ownerShareMessage` / `ownerShareMessageNoName`. MYR-184 handed the recipient
  the code and nothing else, on the then-true reasoning that there was nowhere to
  send anyone; the client's *"Feels strange just sending a text message, where do
  they go"* was the missing half showing. The public TestFlight link went live
  2026-07-29, so `ShareInviteMessage.compose` now writes the three steps in the
  order they are performed (get the app → sign in with Apple → enter the code),
  with the **code alone on its own line** and the 7-day expiry stated last. The
  URL is a **plain https string** — Messages and Mail auto-detect it, so no
  `LPLinkMetadata`/`NSItemProvider` preview infrastructure exists or is wanted.
  The link lives in ONE constant, `AppDistribution.testFlightPublicJoinURL`
  (ASC ⇢ TestFlight ⇢ **Friends & Family** external group; **capped at 100
  testers**, after which the link refuses new joins and nothing in the client can
  detect it). **Email needed no server**: the same share sheet already reaches
  Mail — the gap was never the transport, it was that the message said nothing.
  ONE presentation serves BOTH the create and the resend path (`doSend` and
  `resendDialogConfig` both just set `handout`), so both get it for free. The
  opening line has **two grammars, not one with a hole in it**: named when the
  account carries a name, first-person ("I shared my Tesla with you") when it does
  not — `UserProfile.firstName` is genuinely nil for anyone Apple did not hand a
  name for on the FIRST authorization. Both scenes are live-path-only (SIM mints
  no code, so it never opens a share sheet at all) and run the **production**
  `LiveShareService.resend` against `ownerShareLive`'s own `DebugShareEndpoint` on
  appear, because the sheet is otherwise behind a Resend → confirm → Resend tap
  chain headless tooling cannot perform. **The share sheet's preview truncates to
  one line**, so a screenshot can only ever prove the opening grammar —
  `ShareInviteMessageUITests` taps the sheet's own **Copy** and asserts the
  pasteboard, which is the only way to see the full delivered string.

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

  **"{Owner}'s {Vehicle}" is conditional, not concatenated** — `VehicleSummary.name` is the owner's OWN nickname and owners name cars after themselves (the canonical server fixture is literally `"Alex's Model 3"`), so prefixing §7.5.5's `ownerFirstName` onto it produced **"Alex's Alex's Model 3"**, which the first `riderInviteJoined` capture showed verbatim. `SharedVehicleTitle.compose` prefixes the owner only when the nickname is not already about them. The §7.0 catalog rows carry **no owner name at all** — only the redeem response does, and only at join time — so "Shared with me" titles on the vehicle nickname alone rather than persisting a name that can go stale.

- Loading states (MYR-326, all **live-path-only**): `ownerConnectingCold` (owner Home in the first moments of a live boot — the `GET /api/vehicles` list is still in flight, so NOTHING is known and even the switcher chip is a placeholder), `ownerConnecting` (**the client's state**: the list landed — his car's name is known and the REAL `MapHeader` renders it — and the cold `/snapshot` has not. MYR-319's 0/0.8/3/9s retry means this routinely lasts >10s on an asleep/in-service car, which is why he screenshotted it; before this issue both scenes were one black screen with a system `ProgressView` and "Connecting to your vehicles…"), `ownerDrivesLoading` (Drives tab, first page in flight — a day heading + three `DriveRow`-shaped placeholders where a spinner and "Loading drives…" used to be), `ownerSettingsLoading` (Settings ⇢ Tesla Account with the fleet list in flight — two row-shaped placeholders instead of "Connecting…"; forces the LIVE linked-vehicle branch via `DebugScene.rendersLiveLinkedVehicles`, the same stand-in-for-a-live-session precedent as `showsLiveSettings`, so `ownerSettings` itself stays byte-identical). All four inject `DebugLoadingFleet`, which parks the app in ONE loading branch and never resolves it — these states have no other capture route, since on a healthy account each lasts milliseconds and the client's needs a real asleep car behind a real auth session. **No simulated scene can reach a skeleton at all**: `SimulatedVehicleFleet.isConnecting` and `SimulatedDrivesFeed.isLoading`/`hasMore` are `false` by construction and Settings only consults the live list when `linkedVehicles` is wired, so the whole drift gate is untouched. Capture each one twice — once normally, once with `xcrun simctl ui <udid> reduce_motion enabled` — to prove the Reduce Motion fallback: the blocks stay, the sweep goes (`MRTShimmerBand` renders nothing).

**Loading ≠ unavailable** (MYR-326) — skeletons render only from genuinely-in-flight branches. The honest end states keep their quiet one-liners and must never be skeletonized: "No drives yet", "No vehicles linked to this account", "Sign-in required to load vehicles", and the new cold-read timeout. That timeout is what makes the rest safe: `LiveVehicleFleet` now bounds the cold `/snapshot` wait to `ColdSnapshotLoad.budget()` (the Kit's whole retry schedule + per-attempt slack, ~21s) and then renders "Can't reach <car> right now" instead of loading forever. Before it, a car that never answered left `isConnecting` true for the whole session — survivable as a spinner, a lie as a shimmering placeholder. Recovery is the existing low-friction one (a resume re-asks; a late snapshot clears the timeout by itself), not a retry button.

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
- **The share message leads with the join link** — alone on its own line directly
  under the opening, BEFORE the TestFlight link, because platforms preview the
  FIRST link and the old ordering produced TestFlight's generic "join the beta"
  tile. The TestFlight link survives as the demoted no-app step (it is still the
  only way to get the build), and the bare code line survives for manual entry.
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
