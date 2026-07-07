# MyRoboTaxi — iOS Build Handoff

> Single source of truth for rebuilding this prototype as a native iOS app.
> Pair with **`Design System.html`** (rendered spec sheet), **`Anatomy.html`** (labeled exploded screens), **`surfaces.html`** (widgets / Dynamic Island / Live Activity), and the live **`prototype.html`**.
> Every color, font, radius, icon, and animation named here resolves to a real definition in the source files below — treat those files as canonical when a number is ambiguous.

---

## 0 · How the prototype is organized

The prototype is React + inline Babel. All visual truth lives in a handful of files under `app/`:

| File | What it owns |
|---|---|
| `app/tokens.js` | `window.T` design tokens (colors, fonts, radii, spacing) **and** `window.SFIcon` — every icon as an inline SVG keyed by its SF Symbol name. |
| `app/design.jsx` | `useSurfaces()` — the **Flat ↔ Liquid Glass** look system. Returns surface/button styles per mode. |
| `app/components.jsx` | Shared components: `Button`, `Toggle`, `Avatar`, `BottomNav`, `BottomSheet`, `HexLogo`, `Wordmark`, `PulseDot`, `MapBackground`, `VehicleMarker`, `RouteLine`, `StatusBadge`, `BatteryBar`, plus the global `@keyframes` in `MRT_STYLES`. |
| `app/screens.jsx` | Owner screens + mock data (`VEHICLES`, `DRIVES`, `VIEWERS`, `PENDING`): `SignInScreen`, `EmptyScreen`, `HomeScreen` (Live Map), `MapHeader` (vehicle switcher), `DrivesScreen`, `DriveSummaryScreen`, `InvitesScreen` (Share), `SettingsScreen`. |
| `app/onboarding.jsx` | `AddTeslaFlow` (owner pairing) + `InviteCodeFlow` (rider join) + `PairStepper`, `InAppBrowser`, `PairedSuccess`, `JoinedSuccess`, `GoldWash`. |
| `app/tutorials.jsx` | `StoryDeck` (paged story-card engine) + `OwnerTutorial` + `RiderTutorial` + all the vignette mini-screens. |
| `app/shared-screens.jsx` | Rider/guest flow: `SharedViewerScreen`, `RideHistoryScreen`, `SharedSettingsScreen`, `ScheduledRideSheet`. |
| `app/ride-request.jsx` | The full request→booking→tracking→summary flow + `IncomingRequestSheet` (owner side). |
| `app/vehicle-controls.jsx` | Lock / climate / media / charge control stack (home half-sheet). |
| `app/phone-frame.jsx` | iPhone 17 Pro bezel, status bar, Dynamic Island (prototype chrome only — not part of the app). |
| `app/app.jsx` | Orchestrator: top-level `role` (owner/shared), `screen` routing, Tweaks panel, design-mode toggle. |

**Two top-level flows** share one kit:
- **Owner** — full vehicle control. Tabs: Vehicle · Drives · Share · Settings.
- **Shared** (guest / rider) — can request rides + watch the live map. Tabs: Live Map · Ride History · Settings.

---

## 1 · Design tokens (`app/tokens.js` → `window.T`)

### Color
| Token | Hex | Use |
|---|---|---|
| `bg` | `#0A0A0A` | App shell / every screen background |
| `bgSecondary` | `#111111` | Sheet fill (flat), grouped backdrops |
| `surface` | `#1A1A1A` | Cards, input fields |
| `surfaceHov` | `#222222` | Pressed/hover card |
| `elevated` | `#2A2A2A` | Toggle track (off), progress track, chips |
| `text` | `#FFFFFF` | Headlines + body |
| `textSec` | `#A0A0A0` | Subtitles, secondary body |
| `textMuted` | `#6B6B6B` | Labels, timestamps, offline |
| `gold` | `#C9A84C` | **Sacred accent** — CTAs, active nav, vehicle marker, route, brand. Never decorative. |
| `goldLight` | `#D4C88A` | Pressed / highlight, brand-mark top facet |
| `goldDark` | `#A0862E` | Brand-mark bottom facet, deep shadow |
| `goldDeep` | `#8C6E2A` | **Deep antique gold-brown** — pairing stepper (done/active), gold-brown flat buttons |
| `goldDeepSoft` | `#B49A56` | Stepper labels + active numerals |
| `goldGlow6` / `goldGlow3` | `rgba(201,168,76,0.6/0.3)` | Glows, gold washes |
| `driving` | `#30D158` | En-route dot, origin marker, online viewer, success toasts checkmark |
| `parked` | `#3B82F6` | Parked dot |
| `charging` | `#FFD60A` | Charging, seat-heater levels |
| `batLow` / danger | `#FF3B30` | Low battery, destructive actions (revoke/cancel/unlink/sign-out). Dialogs use `#FF6B6B` for the softer on-dark red. |
| `border` | `#1F1F1F` | Hairline 0.5pt dividers + card strokes |

### Type — SF Pro (system), for Dynamic Type
`font` = `-apple-system, "SF Pro Text/Display", system-ui`. Hero numbers use `.monospacedDigit()`.
Scale: Screen Title 28/600 (-0.6 track) · Hero Number 28–40/300 mono · Section Title 18/600 · Body 14–15/400 · Label 10–12/500 uppercase +1.2 track · Tab 10/500.

### Spacing & Radius
Page gutter `24` · card gap `12` · card radius `16` (flat 14) · input/button radius `12` · sheet radius `24` (liquid 30). Min tap target **44pt**.

---

## 2 · The two-look system (`app/design.jsx`)

`useSurfaces()` returns styles for the current mode (persisted Tweak `design`):
- **Flat** — solid `surface` fills, hairline borders. The baseline; also the fallback for < iOS 26.
- **Liquid Glass** — `.ultraThinMaterial` / `glassEffect()` equivalents: translucent fills, sheen gradient, soft rim shadow, pill-rounded buttons (`h/2`).

On iOS: use the native glass APIs on 26+, map Flat → solid `.mrtSurface` below that. `Button(variant:)` and every sheet/card reads its surface from here — don't hardcode.

---

## 3 · Buttons (`Button` in `app/components.jsx`) — 6 variants

| Variant | Look | Use |
|---|---|---|
| `gold` | Solid gold fill, near-black label `#1a1408` | Confirm / commit / send (primary) |
| `outline` | Gold-tinted translucent, gold border | Secondary |
| `outline-muted` | Neutral translucent, white label | Tertiary / cancel-adjacent |
| `outline-draw` | **Animated gold border trace** (2.6s) + gold label + `mrt-gold-pulse` text | **Reserved for the in-app ride-request CTAs only** (Request from…, Confirm pickup, Accept & send, See you soon). This is the "actionable moment" treatment — do not overuse. |
| `outline-static` | Static gold outline on near-black, gold label — the resting look of outline-draw, no animation | Onboarding + tutorial buttons (Sign in with Tesla, Open Tesla app, Continue, etc.) |
| `ghost` | Transparent, secondary label | Inline text actions |

Heights: sm 38 · md 46 · lg 52. Press → scale 0.98. Flat radius 12; Liquid radius h/2.

---

## 4 · Icons (`window.SFIcon`, `app/tokens.js`)

Every icon is an inline SVG keyed by its **exact SF Symbol name** — swap 1:1 for `Image(systemName:)`. Names in use: `car.fill`, `clock.fill`, `person.2.fill`, `person.fill`, `gearshape.fill`, `map.fill`, `location.fill`, `locate`, `mappin`, `mappin.circle.fill`, `magnifyingglass`, `paperplane.fill`, `bolt.fill`, `bag`/`bag.fill`, `calendar`, `checkmark`, `xmark`, `plus`, `chevron.left/right/down`, `lock.fill`, `lock.open.fill`, `fan`, `snowflake`, `sun.max.fill`, `thermometer`, `speedometer`, `gauge`, `wind`, `play.fill`/`pause.fill`/`forward.fill`/`backward.fill`, `speaker.wave.2.fill`, `bell`, `pencil`, `square.and.arrow.up`, `arrow.up.right`, `envelope.fill`, `apple.logo`, `battery.100`, `house.fill`, `briefcase.fill`, `figure.wave`/`figure.run`, `face.smiling`. Keep custom vectors only for the **brand mark** (`HexLogo`/`ArrowMark`) and the **vehicle marker**.

---

## 5 · Flows — screen by screen

### 5.1 Onboarding entry
- **SignInScreen** — brand mark + animated particle "glimpse" line; swipe up (or tap) reveals an **Apple-only** sheet → `Sign in with Apple` → gold bloom hands into the app. Sole auth method for both flows (AuthenticationServices / `ASAuthorizationAppleIDButton`).
- **EmptyScreen** — first run. Gold wash from top + brand mark + "Welcome to MyRoboTaxi / How would you like to get started?" then **two self-describing choice cards** (icon + title + one-line descriptor, shared shape/radius/border):
  - *Add your Tesla* — emphasized: gold-tinted fill + solid gold border, gold car icon → `AddTeslaFlow`.
  - *Join with an invite code* — quiet matching card, person icon → `InviteCodeFlow`.

### 5.2 Add Your Tesla — owner pairing (`AddTeslaFlow`)
A 4-step tracked flow with a persistent **`PairStepper`** (Sign in → Linked → Virtual key → Paired; done steps fill `goldDeep`, active ring + numeral `goldDeepSoft`). Cancel action top-right; stepper sits at `top:124` to clear it.

Phases:
1. **intro** — brand mark with expanding `mrtRingPulse` rings, "Connect your Tesla", `Sign in with Tesla` (outline-static). Secured-by-Tesla note.
2. **In-app browser** (`InAppBrowser`) — a Safari-View-Controller-style sheet slides up (`translateY` 100%→0, `.42s` spring), faux `auth.tesla.com` chrome with Cancel. Views: **auth** (email prefilled + password → Sign In) → **consent** (Tesla ↔ MyRoboTaxi handoff header + 4 scope rows: Vehicle info, Location, Commands, Charging → Allow access) → **connecting** (spinner ~1.15s) → **auto-dismiss the instant access is granted**.
   - ⚠️ These Tesla screens are **original plausible mocks, NOT Tesla's real UI**. On iOS, replace with `ASWebAuthenticationSession` against the real **Tesla Fleet OAuth**; the consent/scopes are illustrative.
3. **key** — "Tesla account linked" confirmation banner (glass capsule; animated: badge pop + expanding ring + drawing checkmark + text reveal), then a **virtual key card** (matte-black, brand mark + contactless glyph + "VIRTUAL KEY · MyRoboTaxi", diagonal **shimmer** sweep `mrtShimmer` 2.4s) → `Open Tesla app` (outline-static).
   - ⚠️ Maps to Tesla's real **virtual-key (BLE) enrollment**; the "Open Tesla app" handoff is simulated on a timer in the prototype.
4. **waiting** — "Waiting for approval…" with pulsing key + `mrtWaitDot` dots (simulated 2.4s).
5. **paired** (`PairedSuccess`) — **celebratory**: gold radial `mrtPairBloom` + expanding rings + `mrtCheckPop` gold check → "You're paired" → vehicle card **rises in** (`mrtCardRise`) showing name/model/color/plate/virtual-key Active. `Continue` → **OwnerTutorial**.

### 5.3 Enter Invite Code — rider join (`InviteCodeFlow`)
Gold wash + brand mark + "Enter invite code". **6 cells** backed by a hidden input with an animated caret; active cell gets a gold ring. Invalid → `mrtShake`. "Use sample code →" shortcut. On 6th char → **validating** spinner (~1.3s) → **joined** (`JoinedSuccess`): gold bloom + check + "You're in" + host card (avatar + "Alex's Model Y" + relationship). `Continue` → **RiderTutorial**.
- When launched **from rider Settings** (returning), it skips the tutorial and returns to Settings; CTA reads **"Done"** (`returning` prop).

### 5.4 Tutorials (`StoryDeck` in `app/tutorials.jsx`)
Paged **story cards** (Things/Linear style): each card = a floating hero **vignette built from real app primitives** (mini map with route + marker, drive rows, sharing rows, request card, controls grid, etc.) + big title + body + **page dots** + outline-static CTA. Kicker + Skip pinned top (below status bar, `top:84`/`top:82`). Swipe (pointer drag) or tap Continue; dots jump; last card fires `onDone`.
- **OwnerTutorial** — 5 cards: Live map & status · Drive history · Sharing with people you trust · Send the car (ride requests) · Comfort/controls. → Live Map.
- **RiderTutorial** — 5 cards: Request a ride · Track every minute (live ETA) · Rides saved · Cars shared with you · Clear boundaries (safety: request+watch only, never drive). → Shared Live Map.
- iOS: `TabView(.page)` with `mrtStoryInL/R` directional slide; vignettes bob with `mrtVigFloat`.

### 5.5 Owner — Live Map (`HomeScreen`)
Map + route + vehicle marker; bottom sheet hero = destination + ETA (driving) or location/battery/duration (parked, 3 peek styles). Sheet drags peek ↔ half; **half reveals `VehicleControls`** (lock, climate, media, charge tiles). `MapHeader` = the **vehicle switcher** (see §6). `FloatingMapButton` = recenter.

### 5.6 Owner — Drives / Drive Summary
`DrivesScreen` — grouped History + Upcoming rows; tap → `DriveSummaryScreen` (hero map, stat grid, speed sparkline, FSD share via `UIActivityViewController`). Reserved rides can be cancelled (confirm dialog).

### 5.7 Owner — Share (`InvitesScreen`)
Email field + **Send**. Empty/invalid email → `mrt-invite-shake`. Valid → **send-invite sheet** (§7). Below: **Viewers** list (each with **Revoke** → confirm dialog → success toast) and **Pending** list (each with **Resend** → gold confirm dialog + toast, and **Cancel** → red confirm dialog). All list mutations are real local state.

### 5.8 Owner — Settings (`SettingsScreen`)
- **Profile**.
- **Tesla Account** — lists **all linked vehicles** with a **Primary** badge; "synced" status. Tap a vehicle → **detail sheet** explaining what Primary means (default on map + used for new requests/sharing) with **Set as primary** (gold) and **Unlink this Tesla** (red → confirm dialog; unlinking promotes the next vehicle to primary). **Add another Tesla** → `AddTeslaFlow`.
- **Shared with** — viewer list with **Revoke** (confirm dialog + toast). **Invite someone** → Share screen.
- **Notifications** toggles. **Sign out** (red) → confirm dialog → returns to SignInScreen.

### 5.9 Rider — Settings (`SharedSettingsScreen`)
Profile · **Shared with me** (whose Teslas you can ride, each with access level) + an **Enter invite code** row → `InviteCodeFlow` (returning) · notifications · **Sign out** (confirm dialog, guest copy) → SignInScreen.

### 5.10 Rider — request → tracking → summary (`app/ride-request.jsx`)
Idle → Search (rotating placeholder, saved places, drop-a-pin) → Pin drop → Review (choose whose Tesla; **request CTA = outline-draw**) → Booking/Sending (gold fill slides over a 10s window; tap fast-forwards → "Request sent") → owner accepts → Tracking (two-leg, plate hero, shimmering "Arriving") → **Ride Summary** takeover (greeting, route snippet, stat strip, joke tip row → deadpan sheet). Owner side: `IncomingRequestSheet` (accept → sending → sent → dispatch; scheduled variant reserves for later).

---

## 6 · Vehicle switcher (`MapHeader`, `app/screens.jsx`)
Top-center **capsule chip**: car icon + current vehicle name + chevron (40pt tall, glass). Tap → **picker menu** listing each vehicle (icon, name, plate, checkmark on active); select switches + closes, tap-outside dismisses. Collapses to a plain label when only one vehicle. (Replaces the old page-dots, which were sub-44pt and read as decoration.) iOS: `Menu` or a custom popover; avoid gesture conflict with `MKMapView` pan.

---

## 7 · Reusable overlay patterns (build these as shared views)

### Confirmation dialog (center alert)
Used by: revoke access, cancel invite, unlink Tesla, cancel reservation, sign out.
- Backdrop `rgba(0,0,0,0.6)` (`mrt-fade-up`), card `#1a1a1c`, radius 22, max-width 300, centered, rises with `mrt-sched-up` (~.28s spring).
- Layout: 46×46 tinted icon circle (red `rgba(255,59,48,0.14)` for destructive, gold for positive) → title 17/600 → body 13 `textSec` naming the subject → stacked buttons: **destructive** = `rgba(255,59,48,0.16)` fill / `#FF6B6B` label; **positive** = gold fill; **dismiss** = outline-muted ("Keep access" / "Keep invite" / "Keep linked" / "Cancel" / "Not now").

### Success toast
Used by: access revoked, invite sent, invite resent.
- Bottom-anchored (`bottom:116`, above tab bar), pill `#22221f` + gold hairline border, gold `checkmark` + message. Slides up `mrt-sched-up`, **auto-dismisses ~2.8s**.

### Bottom-sheet config (send-invite, vehicle detail)
- Slides from bottom (radius 26 top corners, `mrt-sched-up` ~.34s), grab handle, optional close ✕.
- **Send-invite sheet**: recipient row (avatar + name + email) → **Vehicles** multi-select (checkbox cards, "select one or more", ≥1 enforced) → **Access** cumulative tiers (Live location → Live + history → Can request rides; each "Everything above, plus…") → a live **summary card** listing exactly which capabilities are granted → **Send invite** → sending spinner → gold check "Invite sent" → adds to Pending + toast.

---

## 8 · Motion (`@keyframes`; see `MOTION_TOKENS` in `ds/ds-data.jsx`)
Calm + physical. Only live elements loop. **Honor Reduce Motion** — traces/pulses fall back to static (already wired via `@media (prefers-reduced-motion)`).

Named animations and where they live:
- **Sheet snap** `.42s cubic-bezier(.32,.72,0,1)` → `.spring(response:0.42, dampingFraction:0.86)` — sheet detents.
- **Confirm dialog / Toast / Bottom-sheet** — `mrt-sched-up` + `mrt-fade-up` (§7).
- **Border trace** `2.6s linear` (`mrt-trace-spin`) — request CTA + search bar (`AngularGradient` + rotation). Static fallback on Reduce Motion.
- **Send fill** `10s linear` — sending CTA gold fill L→R.
- **Title shimmer / Key shimmer** — masked gradient sweep across gold text / the virtual key card (`mrtShimmer`).
- **Pair bloom** `.9s` (`mrtPairBloom`) + **Check pop** (`mrtCheckPop`) + **Card rise** (`mrtCardRise`) — paired/joined celebration.
- **Ring pulse** (`mrtRingPulse` / `mrt-pulse-ring`) — live marker, key waiting, intro rings.
- **Story slide** `.45s` (`mrtStoryInL/R`) + **Vignette float** `4s` (`mrtVigFloat`) — tutorials.
- **Greeting glow** `.85s` — time-of-day greeting.
- **Code/email shake** `.4s` (`mrtShake` / `mrt-invite-shake`).
- **Wait dots** (`mrtWaitDot`), **caret blink** (`mrtCaretBlink`) — pairing wait + invite code.

---

## 9 · Deviations & open questions
See the **Handoff notes** section of `Design System.html` (`DEVIATIONS` / `OPEN_QUESTIONS` in `ds/ds-data.jsx`) — Mapbox→MapKit, Inter→SF Pro, in-app browser → `ASWebAuthenticationSession` + Tesla Fleet OAuth, virtual key → BLE enrollment, Liquid Glass → native glass APIs, vehicle switcher chip, Live Activity cadence, etc.

---

## 10 · Rebuild checklist
1. Port `window.T` → a `Color`/metrics extension; port the type scale to Dynamic Type text styles.
2. Build `Button(variant:)` with all 6 variants (gate the `outline-draw` trace behind Reduce Motion; use it only on ride CTAs).
3. Build the 3 shared overlays (§7) once, reuse everywhere.
4. Build `PairStepper`, `StoryDeck`, the vehicle switcher chip as reusable views.
5. Implement the Tesla pairing against real Fleet OAuth + BLE key enrollment (the mock screens are illustrative).
6. Wire every list mutation (revoke/cancel/resend/unlink/set-primary/send) to real state + the matching confirm dialog + success toast.
7. Cross-check every screen against `Anatomy.html` for exact spacing/callouts and `prototype.html` for behavior.
