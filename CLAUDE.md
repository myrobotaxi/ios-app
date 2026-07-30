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

- Rider request flow: `idle`, `search`, `searchFiltered`, `searchSelected` (destination chosen, "Continue" CTA), `pinDrop`, `pinDropRealPath` (MYR-217: boots to idle, then auto-drives the REAL idle→search→Continue→pinDrop transition with live updates flowing — use this, not cold `pinDrop`, to probe pin-drop entry camera behavior), `review`, `reviewPicker`, `booking`, `pending` (minimized "Request sent" pill), `trackingLeg1` (to pickup), `trackingLeg2` (in-ride), `trackingArriving`, `summary`, `declined`, `riderBusyVehicle` (MYR-233: the Review sheet with an UNAVAILABLE vehicle — muted Busy chip on the fleet row, gold instant CTA replaced by "Schedule with … instead". Select the state with `MRT_BUSY_REASON=busy|inService|offline`, default `busy`; each is built from real wire inputs through `LiveFleetMemberMapping`, so the capture exercises the shipping predicate), `riderPlateChip` (MYR-286: the Booking sheet's plate chip carrying the REAL owner-entered plate instead of the `VIN ····xxxx` degrade — same live-shaped `VehicleSummary` path, with `licensePlate` set), `riderScheduleFloored` (MYR-316: the Schedule slide-up card with the SERVICE-WINDOW FLOOR applied — a muted "Lunar is in service until Sat, Aug 1 · 2:00 PM" caption, dimmed-but-visible day/time chips for every slot before the car is back, and a selection already pulled forward to the first bookable one. Injects a live-shaped in-service `VehicleSummary` carrying `serviceEstimatedEndAt` through the REAL `LiveFleetMemberMapping`, then opens the card via the existing one-shot `opensScheduleOnSearch` hook, so the capture exercises the shipping `RideScheduleFloor` grid rule rather than a hand-set flag. **A vehicle with NO window imposes NO floor** — that is the common case and every other rider scene is byte-identical).
- Rider scheduled-ride sheet: `scheduledDetails`, `scheduledReschedule`, `scheduledRequested`, `scheduledConfirmCancel`.
- Owner side: `ownerHome`, `ownerDrives` (Drives tab, `initialOwnerTab` "drives"), `ownerIncoming`, `ownerIncomingQueued` (MYR-317: the SAME incoming card with the queue badge up — a muted "+2 more waiting" chip trailing the "INCOMING RIDE REQUEST" kicker, the owner's only signal that resolving this card is not the end of the queue. The simulated service has no incoming FEED, so the count comes from its DEBUG-only `debugSeedWaitingIncoming`; the live service derives the identical number from the held incoming page. Everything else is `ownerIncoming` verbatim, so the pair is a clean before/after of exactly the chip — `ownerIncoming` itself stays pixel-identical), `ownerScheduled`, `ownerScheduledLive` (MYR-312/313: the SCHEDULED incoming card on the **live** branch, in the client's condition — Saturday 5:30 PM reservation, target car IN SERVICE now. The only scene that forces `HomeScreen`'s live rendering (`DebugScene.rendersLiveIncomingRequest`), because the real requester name and the scheduled accept-gate exemption are both live-only branches a sim capture can't reach; it injects an in-service `DebugVehicleDetailsFleet` the seeded record targets by id, so the real fleet join + the real `isAcceptGated` predicate both run. `ownerScheduled` stays simulated and pixel-identical), `ownerVehicleEnriched` (MYR-320: the vehicle-details section with every enrichment field populated off ONE live-shaped snapshot — Model "2026 Model Y Performance" composed from the display-ready `trimLabel` while the snapshot ALSO carries the raw `trim` badge "p74d" it must NOT substitute, Color "Quicksilver" flowing through the EXISTING `VehicleState.color` with no mapping change, and an "FSD" row reading "FSD (Supervised) v14.3.5" verbatim directly after Software. `ownerVehicleDetails` keeps the pre-enrichment shape — blank color, no FSD row — so the pair is a clean before/after. Pair with `MRT_OWNER_DETENT=half`), `ownerServiceWindowManual` (MYR-320: the same in-service car as `ownerServiceWindow`, with the renamed "Service completion date" row carrying its manual sub-caption "Set manually — Tesla hasn’t provided an estimate for this visit". That caption is only reachable after a save whose echo matched the owner’s submission — proof Tesla held no estimate — which headless tooling cannot perform, so the scene seeds the provenance THROUGH the shipping `LiveVehicleCommandExecutor.provenance` classifier. The wire carries NO source discriminator, so a cold read renders no caption at all), `ownerVehiclePlate` (MYR-286: the Vehicle details section with a real owner-entered plate on BOTH read surfaces — pair with `MRT_OWNER_DETENT=half`; the same scene without a plate is `ownerVehicleDetails`, which now shows the "Add plate" affordance rather than an uneditable VIN), `ownerServiceWindowSaved` (MYR-316, client defect: the owner saved a completion date, the server persisted it, and the sheet kept showing the old state. The same in-service car whose snapshot carries **NO** window — the state the sheet is in when the editor opens — with the production `LiveVehicleCommandExecutor.setServiceWindow` run against `DebugServiceWindowEndpoint` on boot and **nothing refetching the snapshot afterwards** (the field is snapshot-only by contract). Everything the capture shows about the window therefore came from the write ECHO, through the unified `VehicleServiceWindow.resolvedEndAt`; before the fix both read surfaces took the still-empty snapshot and this scene rendered no line and no time at all. Capture at PEEK for the hero line, pair with `MRT_OWNER_DETENT=half` for the row), `ownerNoticeRejected` (MYR-301, client defect: "The car didn’t accept that" stuck forever. A real 502 `command_failed` on `auto_conditioning_stop` settles the real `.rejected` notice, which now clears itself after `LiveVehicleCommandExecutor.defaultNoticeDisplayDuration` (6s) — so capture at t≈2s and t≈8s, the same two-shot pattern `ownerDispatchedCompleted` uses. **That bounded display applies to `ownerNoticeCharge`/`ownerNoticeAsleep`/`ownerNoticeSeat` too**: take their captures inside the window. Pair with `MRT_OWNER_DETENT=half`), `ownerNoticeRejectedInService` (MYR-329, client defect: the SAME rejection with the reason NAMED. Jul 28: "Any reason why car didn't accept climate, is it because low battery?" — the car was in service mode and the battery was fine, but `ownerNoticeRejected`'s generic "The car didn't accept that" left a wrong guess as the only guess available. Same 502 `command_failed` on `auto_conditioning_stop`, same real `LiveVehicleCommandExecutor`, same real `.rejected` settle — the ONE difference is that the wire error carries the server's canonical token in `message` (`"vehicle command failed: vehicle_in_service"`, rest-api.md §7.9), so the shipping `RestError.commandRejectionReason` parse runs and the row reads "Car is in service — commands are limited". Nothing about the notice is hand-set. The tile sub stays "Declined" for every reason — the reason lives on the full-width row, which has the space to say it properly. It needs its own scene because `ownerNoticeRejected` is MYR-301's lifecycle capture and stays byte-identical, and because this state has no other capture route at all: it takes a car genuinely sitting in service mode, behind a real auth session, refusing a real command. The pair is a clean before/after of exactly that one line. Same TWO-SHOT bounded display — t≈2s and t≈8s. Pair with `MRT_OWNER_DETENT=half`), `ownerVehicleSeatsHeatOnly` (MYR-308: the seat section for a car whose REST SPEC says it has NO cooled seats — `DebugVehicleDetailsFleet(ventedSeatReadBacks: true, seatCoolingCapable: false)` carries BOTH the cooler read-backs that make the MYR-299 presence heuristic fire AND the contracts-0.16.0 `seatCoolingCapable: false` that authoritatively overrules it, so the capture is the precedence proof: "SEAT HEATING", flame-only rows, and no Heat↔Cool toggle at all — not even a greyed-out one, which would imply hardware the car lacks. Pair with `MRT_OWNER_DETENT=half`), `ownerMediaNowPlaying` (MYR-303: the Media card with a REAL now-playing block off the wire — title/artist/album/source plus a real duration + sane elapsed, mapped by the production `VehicleContractMapping.nowPlaying` and reconciled by the real `LiveVehicleCommandExecutor`. Shows the shipping render: the prototype media card's title/artist grammar, a PASSIVE progress line (no thumb — §7.9 has no seek-to-position), no invented cover art (the wire carries no artwork), and a live transport row whose icon is the car's own `Playing`), `ownerMediaNoSession` (MYR-314: the same card with NO media session — the car cleared the title to `""` and reports no `mediaPlaybackStatus`. Both halves of one real situation: the honest idle line instead of the track that just ended, and the muted, non-interactive transport row with "Start media in the car first". Pair both media scenes with `MRT_OWNER_DETENT=half`), `ownerFreshnessStale` / `ownerFreshnessWaking` (MYR-315: the owner sheet's tappable **freshness stamp**, which is **LIVE-ONLY** — the prototype has no recency element in the sheet hero at all, and a simulated snapshot carries no `isStreaming`/`lastUpdated` to be honest with, so on the simulated path the stamp is never constructed and every other owner scene stays byte-identical. Both scenes inject `DebugFreshnessFleet` — a car OFFLINE for 7h whose live-shaped `VehicleState` travels the production `VehicleContractMapping`, so the stamp shown is the one the shipping resolver produced — and force `HomeScreen`'s live branch via `DebugScene.rendersLiveVehicleFreshness`. `ownerFreshnessStale` is the resting "Synced 7h ago"; `ownerFreshnessWaking` is the in-flight "Waking Lunar…", seeded as a phase (`initialRefreshPhase`) because headless capture tooling can't synthesize the tap. Capture at PEEK — where the stamp matters most, since the tile qualifiers + "Not live" footer only exist at half, below a scroll — or pair with `MRT_OWNER_DETENT=half`), `ownerServiceWindow` / `ownerServiceWindowEditor` (MYR-316: the owner's side of the service window, injected as `DebugVehicleDetailsFleet(status: .inService, serviceEstimatedEndAt: <next Sat 2 PM>)` — the instant rides BOTH read surfaces (live-shaped snapshot AND list row) exactly as a real server emits it and travels the production `VehicleContractMapping` folds. `ownerServiceWindow` is the READ: the In Service badge with a muted "Service Estimated Completion · Sat, Aug 1 · 2:00 PM" directly beneath it, best captured at PEEK where the line lives; pair with `MRT_OWNER_DETENT=half` to also see the Status & location card's matching In Service chip + the "Expected back" row. `ownerServiceWindowEditor` is the WRITE: the same car with the entry sheet already presented, seeded via `DebugScene.opensServiceWindowEditor` because the row lives inside a half-detent scroll that headless tooling cannot tap — the same stand-in-for-a-tap precedent as `ownerFreshnessWaking`. Its Save runs the production `LiveVehicleCommandExecutor.setServiceWindow` against `DebugServiceWindowEndpoint`, which reproduces the two server behaviours that shape the client: future-only validation, and **Tesla precedence** — the echo is Tesla's `service_etc` when one exists, NOT the owner's submission, which is why the executor adopts the echo. Both scenes leave every other owner scene byte-identical: a car that is not in service renders no line and no row), `ownerDispatchedCompleted` (MYR-292: owner Home holding a `completed` ride — boots with the "Dropped off ✓" banner UP; the 5s auto-dismiss then acknowledges the ride on `OwnerHomeState`, so capture at t≈2s and t≈8s to get both halves. The acknowledgement is owner-scoped state, NOT `HomeScreen` @State, so it survives the tab switch that used to bring the banner back).

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

  **"{Owner}'s {Vehicle}" is conditional, not concatenated** — `VehicleSummary.name` is the owner's OWN nickname and owners name cars after themselves (the canonical server fixture is literally `"Alex's Model 3"`), so prefixing §7.5.5's `ownerFirstName` onto it produced **"Alex's Alex's Model 3"**, which the first `riderInviteJoined` capture showed verbatim. `SharedVehicleTitle.compose` prefixes the owner only when the nickname is not already about them. The §7.0 catalog rows carry **no owner name at all** — only the redeem response does, and only at join time — so "Shared with me" titles on the vehicle nickname alone rather than persisting a name that can go stale.

- Loading states (MYR-326, all **live-path-only**): `ownerConnectingCold` (owner Home in the first moments of a live boot — the `GET /api/vehicles` list is still in flight, so NOTHING is known and even the switcher chip is a placeholder), `ownerConnecting` (**the client's state**: the list landed — his car's name is known and the REAL `MapHeader` renders it — and the cold `/snapshot` has not. MYR-319's 0/0.8/3/9s retry means this routinely lasts >10s on an asleep/in-service car, which is why he screenshotted it; before this issue both scenes were one black screen with a system `ProgressView` and "Connecting to your vehicles…"), `ownerDrivesLoading` (Drives tab, first page in flight — a day heading + three `DriveRow`-shaped placeholders where a spinner and "Loading drives…" used to be), `ownerSettingsLoading` (Settings ⇢ Tesla Account with the fleet list in flight — two row-shaped placeholders instead of "Connecting…"; forces the LIVE linked-vehicle branch via `DebugScene.rendersLiveLinkedVehicles`, the same stand-in-for-a-live-session precedent as `showsLiveSettings`, so `ownerSettings` itself stays byte-identical). All four inject `DebugLoadingFleet`, which parks the app in ONE loading branch and never resolves it — these states have no other capture route, since on a healthy account each lasts milliseconds and the client's needs a real asleep car behind a real auth session. **No simulated scene can reach a skeleton at all**: `SimulatedVehicleFleet.isConnecting` and `SimulatedDrivesFeed.isLoading`/`hasMore` are `false` by construction and Settings only consults the live list when `linkedVehicles` is wired, so the whole drift gate is untouched. Capture each one twice — once normally, once with `xcrun simctl ui <udid> reduce_motion enabled` — to prove the Reduce Motion fallback: the blocks stay, the sweep goes (`MRTShimmerBand` renders nothing).

**Loading ≠ unavailable** (MYR-326) — skeletons render only from genuinely-in-flight branches. The honest end states keep their quiet one-liners and must never be skeletonized: "No drives yet", "No vehicles linked to this account", "Sign-in required to load vehicles", and the new cold-read timeout. That timeout is what makes the rest safe: `LiveVehicleFleet` now bounds the cold `/snapshot` wait to `ColdSnapshotLoad.budget()` (the Kit's whole retry schedule + per-attempt slack, ~21s) and then renders "Can't reach <car> right now" instead of loading forever. Before it, a car that never answered left `isConnecting` true for the whole session — survivable as a spinner, a lie as a shimmering placeholder. Recovery is the existing low-friction one (a resume re-asks; a late snapshot clears the timeout by itself), not a retry button.

Booking/pending/tracking scenes are seeded WITHOUT arming any timers, so they hold still for a screenshot instead of auto-advancing.

**Owner sheet peek band** (MYR-315) — the peek band is the prototype's 210/280 **plus** `MRTMetrics.homePeekQualifierLineHeight` (24) for each LIVE-ONLY qualifier line the hero actually renders: the freshness stamp and the service-completion line. The prototype's hero has neither, so appending them to a fixed band spent the clearance `BottomSheet` reserves above the floating nav (`components.jsx:542` `padding: '6px 24px 100px'`; the nav's own top edge is 86pt from the physical edge) — the client's "the stamp crowds the menu". Simulated scenes render zero such lines, so they land on 210/280 exactly and stay byte-identical; the in-service and freshness scenes sit 24–48pt taller by design (and their map `bottomContentInset` follows).

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
the prediction to rmse 0.0225). The tint is now the same treatment
**pre-resolved to normal compositing** (`MRTDriveCelebration`, DesignSystem): the
gold opacity ramp that least-squares-reproduces soft-light's own output over this
hero, 0.07→0.09. It asks nothing of the compositor, so it has no failure mode.
The rule generalizes: **never let a blend mode, or any effect needing a backdrop
read, be what stands between the user and a hosted `MKMapView`** — resolve it to
normal compositing and put the number in a token a test can assert on
(`heroTintBlendMode` must stay `.normal`).

The capture route was its own trap: `MRT_SCENE=ownerDrives
MRT_OPEN_FIRST_DRIVE=1` opens `DriveFixtures.drives[0]` — **97% FSD**, so
`isFullFSD` is false and not one celebration layer is ever constructed. The
celebration has no cold-scene route at all; the 100% drive is the SECOND row.
`App/UITests/DriveSummaryGoldWashUITests.swift` reaches it by real taps on the
real navigation path and emits the drift-gate captures (100% at t0/t3/t6 plus the
97% control, which must stay byte-identical) — the same
`ExpandedRouteUITests` precedent, and a live instance of the repo's own "cold
scenes passing while real paths fail" lesson.

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
