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

- Rider request flow: `idle`, `search`, `searchFiltered`, `searchSelected` (destination chosen, "Continue" CTA), `pinDrop`, `pinDropRealPath` (MYR-217: boots to idle, then auto-drives the REAL idle→search→Continue→pinDrop transition with live updates flowing — use this, not cold `pinDrop`, to probe pin-drop entry camera behavior), `review`, `reviewPicker`, `booking`, `pending` (minimized "Request sent" pill), `trackingLeg1` (to pickup), `trackingLeg2` (in-ride), `trackingArriving`, `summary`, `declined`.
- Rider scheduled-ride sheet: `scheduledDetails`, `scheduledReschedule`, `scheduledRequested`, `scheduledConfirmCancel`.
- Owner side: `ownerHome`, `ownerDrives` (Drives tab, `initialOwnerTab` "drives"), `ownerIncoming`, `ownerScheduled`.

Booking/pending/tracking scenes are seeded WITHOUT arming any timers, so they hold still for a screenshot instead of auto-advancing.
