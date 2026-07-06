# MyRoboTaxi iOS

Native SwiftUI iOS app for MyRoboTaxi — track your Tesla on FSD, share rides with friends & family, and request rides from cars shared with you.

Two personas share one design kit:

- **Owner** — full vehicle control. Tabs: Vehicle · Drives · Share · Settings.
- **Rider** (shared/guest) — request rides + watch the live map. Tabs: Live Map · Ride History · Settings.

## Source of truth

- **Design**: the claude.ai design project (see `CLAUDE.md` for access) — `Handoff for Claude Code.md` is the rebuild spec; `Anatomy.html` has labeled exploded screens; `screenshots/` holds reference renders used as the drift gate.
- **Backlog**: Linear project **P9 — iOS App (SwiftUI)** (MYR-161…). Backend tracks: P10 Ride-hailing & Dispatch, P11 Vehicle Commands, P2 sharing/push/auth.
- **Wire contracts**: [`myrobotaxi/contracts`](https://github.com/myrobotaxi/contracts) — payload models are generated, never hand-written.

## Planned structure

```
ios-app/
  App/                    # app target (MyRoboTaxi)
  Packages/
    DesignSystem/         # tokens, type scale, Button(variant:), overlays, primitives (MYR-161/162/163)
    MyRoboTaxiKit/        # thin REST + WS client on contracts-generated types (MYR-21, M2)
```

## Milestones

- **M1** — faithful SwiftUI port of every screen on simulated fixture data (matching the prototype's mocks).
- **M2** — wire live: telemetry WS + REST (owner read path first), then P10/P11/P2 backends as they land.

## Sibling repos

[telemetry](https://github.com/myrobotaxi/telemetry) · [contracts](https://github.com/myrobotaxi/contracts) · [typescript-sdk](https://github.com/myrobotaxi/typescript-sdk) · [react-frontend](https://github.com/myrobotaxi/react-frontend) · [sdk-testbench](https://github.com/myrobotaxi/sdk-testbench)
