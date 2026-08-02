# design/ — complete mirror of the claude.ai design project

**Read-only reference for agents. Not app code. Do not edit anything in this
directory.** It is a byte-exact snapshot of the canonical claude.ai design
project (`019e19a0-1707-77b7-a71e-97e4f5ed5769`). The claude.ai project stays
canonical; the orchestrator re-syncs this mirror when the design changes.

**Full sync: 2026-07-06** — every text file in the project (all `app/*`,
`ds/*`, canvases, Handoff). **Partial sync 2026-07-31 (MYR-398 v2)**:
`Handoff-Live-Activity.md` + `la/` — the client's Live Activity / Dynamic Island
redesign, authored after the full sync and mirrored here with the PR that ports
it, so the mirror does not lag the surface it describes. **MYR-412 (2026-08-02)
annotates `Handoff-Live-Activity.md` in place** — the client sent the board image
to correct how the compact trailing slot had been read, so the corrections are
marked ⚠️ inline beside the prose they override rather than replacing it, and the
whole reading is stated once in the mirror note at the top of that file.
`la/la-board.jsx` (the review board those mocks live on) is still **not mirrored**;
the corrected reading of it is what the note carries. Not mirrored:
`screenshots/` and `uploads/`
(iterative design-process images, not canonical references — the runnable
prototype below supersedes them).

## Running the actual prototype (the feature + animation reference)

The prototype is fully self-contained here (React/Babel via CDN):

```sh
cd design && python3 -m http.server 8722 --bind 127.0.0.1
# → http://127.0.0.1:8722/prototype.html
```

A Chrome instance with remote debugging runs on this machine
(`--remote-debugging-port=9222`, profile `~/.cache/mrt-chrome-debug`) — drive
it with the chrome-devtools MCP tools (load via ToolSearch). If Chrome isn't
up: `open -a "Google Chrome" --args --remote-debugging-port=9222
--user-data-dir="$HOME/.cache/mrt-chrome-debug" --no-first-run`.

In the left panel:
- **Flow**: Owner / Shared — switches persona (tabs + screens).
- **Appearance**: ⚠️ **always set to Flat** — the app ships Flat only
  (product decision 2026-07-06); Liquid Glass is out of scope.
- **Screens list**: jump to any screen; interact inside the phone frame to
  reach every state (drag the sheet, run the pairing flow, request a ride…).
- Other canvases: `Anatomy.html` (labeled exploded screens),
  `surfaces.html` (Dynamic Island / Live Activity / widgets),
  `Design System.html` (rendered spec).

**Animations**: watch them live in the prototype, then match the spec —
`Handoff for Claude Code.md` §8 names every animation with duration + curve,
`app/components.jsx` (`MRT_STYLES`) and the flow files hold the exact
`@keyframes` and their `prefers-reduced-motion` fallbacks. A screen PR is not
done until its motion matches the prototype (sequence, duration, curve) and
degrades correctly under Reduce Motion.

## Map of what lives where

| File | Owns |
|---|---|
| `Handoff for Claude Code.md` | The rebuild spec — read first |
| `app/tokens.js` | `window.T` tokens + `SFIcon` (exact SF Symbol names) |
| `app/design.jsx` | `useSurfaces()` — port only the **flat** branches |
| `app/components.jsx` | Shared components + global `@keyframes` |
| `app/screens.jsx` | Owner screens + mock data (`VEHICLES`, `DRIVES`, …) |
| `app/onboarding.jsx` | AddTeslaFlow, InviteCodeFlow, PairStepper |
| `app/tutorials.jsx` | StoryDeck + Owner/Rider tutorials |
| `app/shared-screens.jsx` | Rider: RideHistory, SharedSettings, ScheduledRideSheet |
| `app/ride-request.jsx` | Request→booking→tracking→summary + IncomingRequestSheet |
| `app/vehicle-controls.jsx` | Lock/climate/media/charge stack |
| `app/app.jsx` | Role/screen routing, `REQUESTED/SCHEDULED_RIDES` fixtures |
| `app/phone-frame.jsx`, `ios-frame.jsx`, `tweaks-panel.jsx`, `design-canvas.jsx` | Prototype chrome only — never port |
| `ds/ds-data.jsx` | **Canonical** DEVIATIONS / OPEN_QUESTIONS / MOTION_TOKENS |
| `ds/anatomy-*.jsx` + `Anatomy.html` | Labeled exploded screens |
| `app/surfaces.jsx` + `surfaces.html` | DI / Live Activity / widget specs — **SUPERSEDED for the Live Activity** by `Handoff-Live-Activity.md` + `la/` below (its `decisions` copy is also stale — trust `ds/ds-data.jsx`; auth is Apple-only) |
| `Handoff-Live-Activity.md` | **The Live Activity + Dynamic Island redesign (r16, MYR-398 v2)** — geometry table, colour table, the render-ready 12-state table, the board's decisions, and the SwiftUI notes. Client-authored. |
| `la/la-data.jsx` | Every state's strings / tones / compact words AS DATA. Its own header: *"This mirrors RideActivityCopy on the client; every string here is a client-side string."* It is the ANSWER KEY — `RideActivityCardTests` walks its twelve rows. |
| `la/la-kit.jsx` | The five parts + the four surfaces as JSX — exact paddings, radii, opacities, sizes. What a capture is measured against. |

If a value here conflicts with anything else, this mirror + the claude.ai
project win. If something seems missing or stale, say so in your report — the
orchestrator re-syncs.
