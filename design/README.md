# design/ — synced mirror of the claude.ai design project

**Read-only reference for agents. Not app code. Do not edit anything in this
directory** — it is a snapshot mirrored from the canonical claude.ai design
project (`019e19a0-1707-77b7-a71e-97e4f5ed5769`), which only the orchestrator
session can reach (the DesignSync tool does not exist for subagents).

- **Canonical source**: the claude.ai design project. If a value here seems
  wrong or a file you need is missing, say so in your report — the
  orchestrator syncs files on demand and will re-mirror.
- **Sync log** (path → synced date):
  - `Handoff for Claude Code.md` — 2026-07-06
  - `app/tokens.js` — 2026-07-06
  - `app/design.jsx` — 2026-07-06
  - `app/components.jsx` — 2026-07-06

Key files still living only in the design project (ask to have them synced
when your issue needs them): `app/screens.jsx`, `app/onboarding.jsx`,
`app/tutorials.jsx`, `app/shared-screens.jsx`, `app/ride-request.jsx`,
`app/vehicle-controls.jsx`, `app/app.jsx`, `app/surfaces.jsx`,
`ds/ds-data.jsx`, the `ds/anatomy-*.jsx` boards, and `screenshots/`.

Note: `Handoff for Claude Code.md` §9 references DEVIATIONS/OPEN_QUESTIONS in
`ds/ds-data.jsx`; a stale contradictory copy exists in `app/surfaces.jsx`
(see Linear MYR-194). ds-data is canonical — auth is **Apple-only**.
