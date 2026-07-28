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

- Rider request flow: `idle`, `search`, `searchFiltered`, `searchSelected` (destination chosen, "Continue" CTA), `pinDrop`, `pinDropRealPath` (MYR-217: boots to idle, then auto-drives the REAL idle→search→Continue→pinDrop transition with live updates flowing — use this, not cold `pinDrop`, to probe pin-drop entry camera behavior), `review`, `reviewPicker`, `booking`, `pending` (minimized "Request sent" pill), `trackingLeg1` (to pickup), `trackingLeg2` (in-ride), `trackingArriving`, `summary`, `declined`, `riderBusyVehicle` (MYR-233: the Review sheet with an UNAVAILABLE vehicle — muted Busy chip on the fleet row, gold instant CTA replaced by "Schedule with … instead". Select the state with `MRT_BUSY_REASON=busy|inService|offline`, default `busy`; each is built from real wire inputs through `LiveFleetMemberMapping`, so the capture exercises the shipping predicate), `riderPlateChip` (MYR-286: the Booking sheet's plate chip carrying the REAL owner-entered plate instead of the `VIN ····xxxx` degrade — same live-shaped `VehicleSummary` path, with `licensePlate` set), `riderScheduleFloored` (MYR-316: the Schedule slide-up card with the SERVICE-WINDOW FLOOR applied — a muted "Lunar is in service until Sat, Aug 1 · 2:00 PM" caption, dimmed-but-visible day/time chips for every slot before the car is back, and a selection already pulled forward to the first bookable one. Injects a live-shaped in-service `VehicleSummary` carrying `serviceEstimatedEndAt` through the REAL `LiveFleetMemberMapping`, then opens the card via the existing one-shot `opensScheduleOnSearch` hook, so the capture exercises the shipping `RideScheduleFloor` grid rule rather than a hand-set flag. **A vehicle with NO window imposes NO floor** — that is the common case and every other rider scene is byte-identical).
- Rider scheduled-ride sheet: `scheduledDetails`, `scheduledReschedule`, `scheduledRequested`, `scheduledConfirmCancel`.
- Owner side: `ownerHome`, `ownerDrives` (Drives tab, `initialOwnerTab` "drives"), `ownerIncoming`, `ownerIncomingQueued` (MYR-317: the SAME incoming card with the queue badge up — a muted "+2 more waiting" chip trailing the "INCOMING RIDE REQUEST" kicker, the owner's only signal that resolving this card is not the end of the queue. The simulated service has no incoming FEED, so the count comes from its DEBUG-only `debugSeedWaitingIncoming`; the live service derives the identical number from the held incoming page. Everything else is `ownerIncoming` verbatim, so the pair is a clean before/after of exactly the chip — `ownerIncoming` itself stays pixel-identical), `ownerScheduled`, `ownerScheduledLive` (MYR-312/313: the SCHEDULED incoming card on the **live** branch, in the client's condition — Saturday 5:30 PM reservation, target car IN SERVICE now. The only scene that forces `HomeScreen`'s live rendering (`DebugScene.rendersLiveIncomingRequest`), because the real requester name and the scheduled accept-gate exemption are both live-only branches a sim capture can't reach; it injects an in-service `DebugVehicleDetailsFleet` the seeded record targets by id, so the real fleet join + the real `isAcceptGated` predicate both run. `ownerScheduled` stays simulated and pixel-identical), `ownerVehicleEnriched` (MYR-320: the vehicle-details section with every enrichment field populated off ONE live-shaped snapshot — Model "2026 Model Y Performance" composed from the display-ready `trimLabel` while the snapshot ALSO carries the raw `trim` badge "p74d" it must NOT substitute, Color "Quicksilver" flowing through the EXISTING `VehicleState.color` with no mapping change, and an "FSD" row reading "FSD (Supervised) v14.3.5" verbatim directly after Software. `ownerVehicleDetails` keeps the pre-enrichment shape — blank color, no FSD row — so the pair is a clean before/after. Pair with `MRT_OWNER_DETENT=half`), `ownerServiceWindowManual` (MYR-320: the same in-service car as `ownerServiceWindow`, with the renamed "Service completion date" row carrying its manual sub-caption "Set manually — Tesla hasn’t provided an estimate for this visit". That caption is only reachable after a save whose echo matched the owner’s submission — proof Tesla held no estimate — which headless tooling cannot perform, so the scene seeds the provenance THROUGH the shipping `LiveVehicleCommandExecutor.provenance` classifier. The wire carries NO source discriminator, so a cold read renders no caption at all), `ownerVehiclePlate` (MYR-286: the Vehicle details section with a real owner-entered plate on BOTH read surfaces — pair with `MRT_OWNER_DETENT=half`; the same scene without a plate is `ownerVehicleDetails`, which now shows the "Add plate" affordance rather than an uneditable VIN), `ownerVehicleSeatsHeatOnly` (MYR-308: the seat section for a car whose REST SPEC says it has NO cooled seats — `DebugVehicleDetailsFleet(ventedSeatReadBacks: true, seatCoolingCapable: false)` carries BOTH the cooler read-backs that make the MYR-299 presence heuristic fire AND the contracts-0.16.0 `seatCoolingCapable: false` that authoritatively overrules it, so the capture is the precedence proof: "SEAT HEATING", flame-only rows, and no Heat↔Cool toggle at all — not even a greyed-out one, which would imply hardware the car lacks. Pair with `MRT_OWNER_DETENT=half`), `ownerMediaNowPlaying` (MYR-303: the Media card with a REAL now-playing block off the wire — title/artist/album/source plus a real duration + sane elapsed, mapped by the production `VehicleContractMapping.nowPlaying` and reconciled by the real `LiveVehicleCommandExecutor`. Shows the shipping render: the prototype media card's title/artist grammar, a PASSIVE progress line (no thumb — §7.9 has no seek-to-position), no invented cover art (the wire carries no artwork), and a live transport row whose icon is the car's own `Playing`), `ownerMediaNoSession` (MYR-314: the same card with NO media session — the car cleared the title to `""` and reports no `mediaPlaybackStatus`. Both halves of one real situation: the honest idle line instead of the track that just ended, and the muted, non-interactive transport row with "Start media in the car first". Pair both media scenes with `MRT_OWNER_DETENT=half`), `ownerFreshnessStale` / `ownerFreshnessWaking` (MYR-315: the owner sheet's tappable **freshness stamp**, which is **LIVE-ONLY** — the prototype has no recency element in the sheet hero at all, and a simulated snapshot carries no `isStreaming`/`lastUpdated` to be honest with, so on the simulated path the stamp is never constructed and every other owner scene stays byte-identical. Both scenes inject `DebugFreshnessFleet` — a car OFFLINE for 7h whose live-shaped `VehicleState` travels the production `VehicleContractMapping`, so the stamp shown is the one the shipping resolver produced — and force `HomeScreen`'s live branch via `DebugScene.rendersLiveVehicleFreshness`. `ownerFreshnessStale` is the resting "Synced 7h ago"; `ownerFreshnessWaking` is the in-flight "Waking Lunar…", seeded as a phase (`initialRefreshPhase`) because headless capture tooling can't synthesize the tap. Capture at PEEK — where the stamp matters most, since the tile qualifiers + "Not live" footer only exist at half, below a scroll — or pair with `MRT_OWNER_DETENT=half`), `ownerServiceWindow` / `ownerServiceWindowEditor` (MYR-316: the owner's side of the service window, injected as `DebugVehicleDetailsFleet(status: .inService, serviceEstimatedEndAt: <next Sat 2 PM>)` — the instant rides BOTH read surfaces (live-shaped snapshot AND list row) exactly as a real server emits it and travels the production `VehicleContractMapping` folds. `ownerServiceWindow` is the READ: the In Service badge with a muted "Service Estimated Completion · Sat, Aug 1 · 2:00 PM" directly beneath it, best captured at PEEK where the line lives; pair with `MRT_OWNER_DETENT=half` to also see the Status & location card's matching In Service chip + the "Expected back" row. `ownerServiceWindowEditor` is the WRITE: the same car with the entry sheet already presented, seeded via `DebugScene.opensServiceWindowEditor` because the row lives inside a half-detent scroll that headless tooling cannot tap — the same stand-in-for-a-tap precedent as `ownerFreshnessWaking`. Its Save runs the production `LiveVehicleCommandExecutor.setServiceWindow` against `DebugServiceWindowEndpoint`, which reproduces the two server behaviours that shape the client: future-only validation, and **Tesla precedence** — the echo is Tesla's `service_etc` when one exists, NOT the owner's submission, which is why the executor adopts the echo. Both scenes leave every other owner scene byte-identical: a car that is not in service renders no line and no row), `ownerDispatchedCompleted` (MYR-292: owner Home holding a `completed` ride — boots with the "Dropped off ✓" banner UP; the 5s auto-dismiss then acknowledges the ride on `OwnerHomeState`, so capture at t≈2s and t≈8s to get both halves. The acknowledgement is owner-scoped state, NOT `HomeScreen` @State, so it survives the tab switch that used to bring the banner back).

Booking/pending/tracking scenes are seeded WITHOUT arming any timers, so they hold still for a screenshot instead of auto-advancing.

**Owner-sheet capture modifiers** (DEBUG-only, orthogonal to the scene): `MRT_OWNER_DETENT=half` boots at the controls detent — MYR-319 makes it apply on the LIVE fleet too, not just the simulated/injected ones; `MRT_OWNER_VEHICLE=<n>` selects a fleet row; `MRT_OWNER_SCROLL=bottom|<0…1>` (MYR-319) overrides where the dense sheet's scroll rests, so a section can be framed on a scene that carries no per-scene anchor. The last two exist because the ONLY way to see the controls stack fed by a REAL REST snapshot is `MRT_SCENE=ownerHome MRT_TELEMETRY=live MRT_BACKEND_URL=…`, and headless tooling can neither drag nor scroll the sheet. Unset, every existing scene's detent and anchor are exactly as before.

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
