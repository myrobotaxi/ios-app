# Handoff · Live Activity & Dynamic Island (v3)

Rebuilt against the 1.0.0 field report (build `202608010021`, iPhone 18,2 / iOS 26.5.2), with the **Uber ride Live Activity as the structural and copy reference** — that was the team's call. Board: `Live Activity.html`. States as data: `la/la-data.jsx` — port strings from there.

The state machine is unchanged. What each state renders, and every rider-facing string, changed.

---

## 1 · The six things the report called out

| # | Report | Fix | Cost |
|---|---|---|---|
| 1 | *"It's saying arriving while on the way to the destination"* | **The two legs use two different headline forms**, as Uber does. Pickup leg counts down: `Pickup in 8 min`. Trip leg states a clock time: `3:42 PM dropoff`. A duration can never be read as a time of day, and **"Arriving" is retired** from rider-facing copy. | Copy |
| 2 | *"Always show the route line, even without telemetry"* | **The rail is unconditional.** No telemetry = rail at zero, filling in as data lands. Never a missing row. | Layout |
| 3 | *"Line to pickup → finished at pickup → restart → finished at dropoff"* | **One rail per leg**, exactly that sequence. The leg flip is the only event allowed to send progress backward. | Layout |
| 4 | *"All banners the same width and height"* | **350 × 128 in every state**, four fixed-height rows. Terminal states keep the rail (idle) rather than collapsing. | Layout |
| 5 | *"The Island should expand at every state transition"* | All **six phase changes ship an alert configuration** → iOS expands the island ~3s, then collapses to compact itself. | Client |
| 6 | *"Expanded Island is a lot of black space"* | Now just the card's own two content rows: **372 × 96** (was ~150 with an empty row), with no badge competing with the headline. | Layout |

---

## 2 · What we took from Uber

- **Wordmark alone on the top row** — and nothing else. **No badges anywhere on the card.** Every state says what it is in words: the headline carries the status, the subline carries the detail. A pill repeating the headline is noise.
- **The headline leads and is bold** (20/600). It is the first thing read, and the largest thing on the card.
- **The subline carries what that leg needs.** `7SRJ294 · Silver Model Y` while the car is coming — the same string Uber puts in the same slot — then `Heading to Duarte's Tavern` once you're in it. Never a status.
- **The rail is unlabeled.** The subline names the destination, so labels under the rail were redundant — they're gone.
- **Two ETA forms, one per leg.** Countdown to pickup, clock time to dropoff. This is the actual fix for the report's first complaint.
- **No trailing tile.** Uber's is a driver photo; a driverless car has no driver, and we have no vehicle render yet. The slot stays **empty** rather than being filled with a stylized plate badge — the plate is plain text in the subline, which is where Uber also puts it. If a render lands later, that slot is 58–62 × 38–40.
- **Uber's phase names** for engineering: `Dispatch → Enroute → Arriving → Arrived → On trip`. "Arriving" is fine as a phase name; it is never a rider-facing string.
- **Uber's compact-island rule:** a figure or nothing. Ours shows `8 min` / `1 min` / `3:42 PM`, the mark alone where there is no figure, a wave at the pickup and a check at completion.

## 3 · The four rows

Fixed heights, `space-between`. Nothing a state does can change the footprint.

1. **Wordmark row · 20pt** — logo 20, wordmark 10/500 uppercase @42%. Nothing trailing.
2. **Headline · 24pt row** — 20/600, one line. `{Phase} in {n} {unit}` · `{h:mm A} dropoff` · or a status phrase.
3. **Subline · 17pt row** — 13.5/400 @58%, one line, ellipsis. Plate + car on the pickup leg, destination on the trip leg. The plate is *not* stylized — no badge, no box.
4. **Route line · 18pt** — always drawn, **always gold**. 5pt track, gold fill, brand arrow (14) in a 22pt `#0d0b06` puck riding the head, 11pt destination pin. At `p = 1` the pin is removed and the mark stands in its place — the car has become the marker.

Trailing the headline+subline block on the pickup leg: **plate tile 62 × 40**, plate 11.5/600 gold, model 8pt uppercase @40%.

## 4 · Rail contract

```
leg 1   vehicle → pickup        leg 2   pickup → destination

Dispatch                p 0     idle    route known, car isn't
Enroute                 p 0…1   live    fills toward the pickup pin
Arriving                p ~.9   live    same shape, nearly full
Arrived                 p 1     live    pin removed — the mark IS the marker
leg flip → On trip      p 0     live    RESET — the only backward move allowed
On trip                 p 0…1   live
Completed               p 1     live    the only other completed rail
Pushes stopped          hold    live    position held — NOT dimmed
Declined / Cancelled / Expired / Unknown    p 0    idle
```

Two states only: **live** and **idle**. `idle` draws the track and pin with no fill and a 50%-opacity arrow at the origin — an untraveled route, not an error. There is no dimmed variant: when pushes stop, the last known position is still true, so the rail keeps its gold and the subline says `Last updated 3:31 PM`. Clamp `p` monotonically within a leg.

## 5 · Geometry

```
Card         350 × 128 — fixed, every state
             radius 22 · padding 12/15/13 · rows space-between
             ground (opaque — the logo tile backdrop):
               radial-gradient(120% 130% at 14% -20%, rgba(201,168,76,0.13), transparent 58%),
               linear-gradient(155deg, #1b1407 0%, #0d0b06 55%, #090806 100%)
             hairline 0.5px rgba(201,168,76,0.16) · shadow 0 14 38 rgba(0,0,0,0.55)
Rows         wordmark 20 · headline 24 · subline 17 · rail 18
Headline     20/600, tracking −0.45 — "in" and unit 500 @62%, value tabular
Subline      13.5/400 @58%, tracking −0.1, one line
Rail         track 5 (r 2.5) · dest pin 11 (2px ring) · arrow 14 in a 22pt puck
             two states only: live (gold) and idle (no fill, 50% puck)
             puck travel is clamped to the track: left = 11 + (W − 22) × p
             at p = 1 the pin is REMOVED and the mark stands in its place
Chip         — removed. No badges on any surface.
Compact      h 37 · min-w 126 (figure) / 92 (glyph) / 74 (bare) · pad 0/13/0/11
             arrow 16 · figure 15/600 tabular · glyph white 19
             glyphs are real icons, not artwork: Material Symbols Rounded
             `waving_hand` / `check_circle` (FILL 1) on the board — ship the
             SF Symbol equivalents `hand.wave.fill` / `checkmark.circle.fill`.
             White, matching the figures they replace; gold stays the route's.
Minimal      37 × 37 · east arrow 17 centered
Expanded     372 × 96 · r 38 · padding 12/18/14 · gap 9 · logo 28 · headline 19/600
```

Text opacity ladder: **100 / 62 / 58 / 42%** white.

## 6 · Color — and only this

| Token | Hex | Used for |
|---|---|---|
| `gold` | `#C9A84C` | Rail fill · destination pin · brand facet |

One accent, no status colors — there are no tone dots left to carry them. Card ground `#1b1407 → #0d0b06 → #090806`, the logo tile values from `app/components.jsx`.

## 7 · Copy rules

- **Pickup leg counts down.** `Pickup in 8 min` · `Pickup in 1 min`. Minutes — the rider is waiting.
- **Trip leg states a time.** `3:42 PM dropoff`. Long horizon, and unmistakable for a duration.
- **Never "Arriving"** in rider-facing copy. Phase name only.
- **Never `mm:ss`.** `8 min`, not `8:12`. Under 60s: `45 s`.
- **Subline is always a place.** Never a status, never the vehicle.
- **No ETA is a word, not a gap.** `Pickup soon` / `Dropoff soon`, same slot, same size — no badge needed to explain a missing number.
- **Exceptions are sentences.** Stale pushes read `Last updated {h:mm A}` in the subline. No pill, no dimmed rail.
- **No blame on cancel.** `Ride cancelled`.
- **Say "ride", not a model name.** `Your ride is here`, `Finding your ride`. The model appears once, in the subline, as identification.
- One word: **`dropoff`**, not `drop-off`, matching the reference.
- Nameless vehicle → `Your Tesla`.
- `Reservation expired` — headline is the outcome, subline is the reason.

## 8 · State table (render-ready)

| State | Headline | Subline | Rail | Compact |
|---|---|---|---|---|
| Dispatch | `Finding your ride` | `Matching you with a ride` | 0 · idle | mark only |
| Enroute | `Pickup in {n} min` | `{plate} · {color} {model}` | live | `{n} min` |
| Arriving | `Pickup in 1 min` | `{plate} · {color} {model}` | live ~90% | `1 min` |
| Enroute · no ETA | `Pickup soon` | `{plate} · {color} {model}` | live | mark only |
| Enroute · no telemetry | `Pickup soon` | `{plate} · {color} {model}` | 0 · idle | mark only |
| Arrived | `Your ride is here` | `{plate} · {color} {model}` | 1 · live | wave |
| On trip | `{h:mm A} dropoff` | `Heading to {place}` | live | `{h:mm A}` |
| On trip · no ETA | `Dropoff soon` | `Heading to {place}` | live | mark only |
| Pushes stopped | `Dropoff soon` | `Last updated {h:mm A}` | hold · live | last figure |
| Completed | `You've arrived` | `{place}` | 1 · live | check |
| Declined | `No ride available` | `Nothing was charged` | 0 · idle | mark only |
| Cancelled | `Ride cancelled` | `Nothing was charged` | 0 · idle | mark only |
| Reservation expired | `Reservation expired` | `No car arrived in time` | 0 · idle | mark only |
| Unknown *(fallback)* | `Ride in progress` | `Tap to open MyRoboTaxi` | 0 · idle | mark only |

**Chips appear only when the headline can't say it** — they don't, anywhere. Removed from every surface.

## 9 · SwiftUI notes

- **Auto-expand.** Push each phase change with an alert configuration on the content update, which is what makes the island expand and then collapse itself. Alert on the six phase changes only — `Dispatch → Enroute → Arriving → Arrived → On trip → Completed`. Do **not** alert on ETA ticks or the stale flip, or the island strobes.
- **Fixed card height.** `.frame(height: 128)` on the Lock Screen view and a fixed `.frame(height:)` per row. Headline and subline are `lineLimit(1)` + `.truncationMode(.tail)` in every state — never let a `Text` grow the stack.
- **Card ground is a real `ZStack` of the two gradients**, not `.ultraThinMaterial`; the glass was the system default, not a choice. The island stays true black — hardware.
- **Pickup countdown.** `Text(timerInterval:countsDown:)` renders `mm:ss`, so it cannot be used as-is. Use a 1s `TimelineView(.periodic)` (or a custom formatter) emitting `{n} min` / `{n} s`. On stale, swap to `Dropoff soon` — do not freeze the timer view.
- **Trip dropoff time** is a formatted `Date`, not a timer: `.formatted(date: .omitted, time: .shortened)`, recomputed only when the server sends a new ETA. It does not tick.
- **Rail.** One `GeometryReader`; animate fill width and the puck `.offset` with `.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)`. **Clamp puck travel to the track** — `11 + (width − 22) * p` — so it never overhangs the end, and **hide the destination pin at `p = 1`** so the mark occupies that spot alone; two markers stacked on the same point reads as a rendering bug. The arrow is a fixed asset rotated 90° from the mark — never rotate it at runtime.
- **Compact trailing is a figure or nothing.** `8 min` · `1 min` · `3:42 PM`, exactly as Uber does it — never an invented status word. Where Uber has no figure it shows the mark alone (Dispatch) or a glyph (Arrived). Ours: a **wave** at the pickup — same beat as Uber's, the car greeting you — and a **check** at completion. Both gold on a 24 viewBox; the wave renders at 17, the check at 15.
- **Pulsing dot** — removed. Everything on the card is static; the only motion is the rail interpolating on a real update. Live Activities are budget-limited.

---

**Files:** `la/la-data.jsx` (states + transition list as data) · `la/la-kit.jsx` (four rows + four surfaces) · `la/la-board.jsx` (review board) · `Live Activity.html`.
