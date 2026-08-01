# Handoff · Live Activity & Dynamic Island

Design pass over the shipped state machine. **The state machine does not change** — only what each state renders. Board: `Live Activity.html`. Source of truth for the states as data: `la/la-data.jsx`.

---

## 1 · What changed from the shipped build

| # | Change | Why | Cost |
|---|---|---|---|
| 1 | The card sits on the **logo's own brown-black ground**, opaque — not system glass. | It is our surface; it should look like our tile, and an opaque ground survives any wallpaper. | Style |
| 2 | The **brand facet arrow rides the rail head**, banked **due east** (the direction of travel), 13pt inside a 20pt `#0d0b06` disc. Still never re-rotated per progress. | The one element that is unmistakably ours, doing the one job the card exists for. A north-pointing arrow travelling east reads as a bug. | Layout |
| 3 | **Countdown format is `4 min` / `45 s`, never `4:12`.** One uniform type size across the headline: value white-600 tabular, prefix + unit 62%. | `mm:ss` after "Pick up in" reads as a clock time, and the mixed type sizes made the line look broken. Second-precision on a lock card is false precision. | **Copy + layout** |
| 4 | **Status color collapses into a 5pt tone dot** inside the chip. Chip label is always 82% white. | Twelve states × colored text is a dozen colors competing with gold. One dot is enough. | Layout |
| 5 | **Countdown is white, not gold.** Gold stays on rail, destination, arrow. | Gold is the sacred accent; a number that changes every second is not an accent. | Style |
| 6 | **Compact island trailing gets a short status word** on sentence states (Decision 1). | Was falling back to the long status word. | Copy |
| 7 | **Stale chip becomes "Not updating"** with a gray tone dot (Decision 2); the compact island keeps the last known figure at 45%. | The status word is where riders look first. | Copy |
| 8 | Rail gains an **end cap dot** — `goldDeepSoft` on leg 1, `gold` on leg 2, full opacity only at 100%. | Makes "which leg am I on" readable without text. | Layout |
| 10 | **Second line is one place, not a pair** — pickup on leg 1, destination on leg 2. Drops `Meet at ` and the `→` trip line. | The headline states the leg and the rail states the span; a second line that repeats both ends is the busiest row on the card. | Copy |
| 11 | Two **proposed** states filled in: `Requested`, unknown-status fallback. Chips existed; headlines did not. | Both are reachable. | Copy |

---

## 2 · The five parts

1. **Headline** — countdown (`prefix` + `value` + `unit`) or sentence, both at one type size. Sentence wraps to 2 lines max; the countdown never wraps.
2. **Second line** — **one place, never a pair.** Leg 1 = `{pickup}` at 62% white; leg 2 = `{destination}` in gold; terminal: absent. The headline already says which leg you are on, and the rail already shows the span — naming both ends is clutter. (This drops the shipped `Meet at ` prefix and the `{Vehicle} → {Destination}` trip line.)
3. **Progress rail** — 5pt track `rgba(255,255,255,0.13)` + `inset 0 0.5px 0 rgba(255,255,255,0.07)`; gold fill; east-pointing arrow head; end cap. Never backward, resets at leg flip, absent when progress is absent.
4. **Status chip** — 20pt tall, radius 10, 5pt tone dot, 10.5/500 label, `rgba(255,255,255,0.07)` fill + 0.5px `rgba(255,255,255,0.10)` hairline.
5. **Stale notice** — hollow 5pt ring + `Last update {t}`, 11.5pt at 42% white. The word *stale* never appears; the chip carries the warning.

---

## 3 · Geometry

```
Card         width 350 · radius 22 · padding 13/15/14 · gap 10
             ground (opaque — the logo tile backdrop):
               radial-gradient(120% 130% at 14% -20%, rgba(201,168,76,0.13), transparent 58%),
               linear-gradient(155deg, #1b1407 0%, #0d0b06 55%, #090806 100%)
             hairline 0.5px rgba(201,168,76,0.16) · shadow 0 14 38 rgba(0,0,0,0.55)
Brand tile   20 (card) · 26 (expanded island)
Rail         h 5 · r 2.5 · east arrow 13 in a 20pt #0d0b06 disc · cap 5
Chip         h 20 · r 10 · dot 5 · label 10.5/500 · tracking 0.2
Headline     17.5 for both kinds — countdown value 600 tabular (tracking −0.3),
             prefix + unit 500 @62%; sentence 500, tracking −0.3, line-height 1.25
Second line  13.5, tracking −0.1, single line, ellipsis
             leg 1 pickup @62% white · leg 2 destination in gold
Compact      h 37 · min-w 122 · pad 0/13/0/11 · east arrow 16
             label 15/600 tabular (figure) or 14.5/500 (word)
Minimal      37 × 37 · east arrow 17 centered
Expanded     w 372 · r 44 · padding 14/20/18 · gap 12 · countdown 22/600 + unit 14
```

Text opacity ladder over the ground: **100 / 62 / 42%** white. Nothing between.

Countdown copy rule: **`{n} min` above 60s, `{n} s` below.** Never `mm:ss`, and never drop the unit.

## 4 · Color — and only these

| Token | Hex | Used for |
|---|---|---|
| `gold` | `#C9A84C` | Rail fill · destination · active tone dot · brand facet |
| `goldDeepSoft` | `#B49A56` | Leg-1 rail cap · pending tone dot |
| `driving` | `#30D158` | In-ride tone dot |
| `parked` | `#3B82F6` | Dropped-off tone dot |
| `offline` | `#6B6B6B` | Terminal + stale tone dot |

Card ground golds: `#1b1407` → `#0d0b06` → `#090806`, with a `rgba(201,168,76,0.13)` bloom top-left — the same values as the logo tile in `app/components.jsx`.

Rail fill when stale: `#5C5A54` (gold desaturated, same value — the rail stays legible without reading live).

## 5 · State table (render-ready)

| State | Headline | Second line | Rail | Chip · tone | Compact trailing |
|---|---|---|---|---|---|
| Requested *(proposed)* | `{Car} is on its way to you` | `{pickup}` | none | Requested · pending | `Sent` |
| Accepted + ETA | `Pick up in` + `4` + `min` | `{pickup}` | partial, leg 1 | On the way · active | `4 min` |
| Accepted, no ETA | `{Car} is coming to pick you up` | `{pickup}` | only if present | On the way · active | `Coming` |
| Arrived | `{Car} is here` | `{pickup}` | full (server) | Arrived · active, pulsing dot | `Here` |
| En route + ETA | `Arriving in` + `17` + `min` | `{Dest}` · gold | partial, leg 2 | In ride · riding | `17 min` |
| En route, no ETA | `{Car} is taking you there` | `{Dest}` · gold | if present | In ride · riding | `Driving` |
| Stale | status sentence + `Last update {t}` | unchanged | kept, dimmed | **Not updating** · terminal | last figure @45% |
| Completed | `You've arrived at {place}` | — | full | Dropped off · complete | `Done` |
| Declined | `{Car} can't take this ride` | — | none | Declined · terminal | `Ended` |
| Cancelled | `This ride was cancelled` | — | none | Cancelled · terminal | `Ended` |
| Reservation expired | `{Car} didn't make it in time` | — | none | Reservation expired · terminal | `Ended` |
| Unknown *(fallback)* | `{Car} ride in progress` | — | none | Ride · terminal | `Ride` |

Nameless vehicle → `Your Tesla` everywhere, unchanged.

`Reservation expired` is the widest chip in the set — it sets the chip's max width. Keep the headline to one line at that width or the row reflows.

## 6 · Decisions taken on the board

1. **Compact island on sentence states → short status word.** One word, never truncates, changes when the state changes. (Rejected: vehicle name — reads as branding and repeats across five states; arrow-only — the island already has a minimal presentation.)
2. **Stale → stronger.** The chip becomes the warning (`Not updating`, gray dot). Sentence and dimmed rail unchanged.
3. **Completed → no extra beat.** The full rail with the arrow parked on the destination cap *is* the beat; it is the only state where the rail completes. Celebration belongs in the in-app summary. If a beat is mandated later, animate the arrow settling into the cap once on first render — motion, not decoration.

## 7 · SwiftUI notes

- The five parts map 1:1 to five views; `ActivityConfiguration` composes them for the Lock Screen and `DynamicIsland { }` reuses the same views at different sizes. Do not fork the layout.
- **Card ground is a real `ZStack` of the two gradients, not `.ultraThinMaterial`.** Live Activities render the background you give them; the glass was the system default, not a choice. The island stays true black — that one is the hardware.
- Countdown: `Text(timerInterval:countsDown:)` renders `mm:ss`, so it **cannot** be used as-is. Use a 1s `TimelineView(.periodic)` (or `.timerInterval` with a custom formatter) emitting `{n} min` / `{n} s`. On stale, swap the whole headline to the sentence — do not freeze the timer view.
- Compact trailing: figures need `.monospacedDigit()` at 15/semibold; words are 14.5/medium and must not.
- Arrow head: a fixed asset rotated 90° from the mark. Animate `.offset` inside a `GeometryReader` with `.animation(.timingCurve(0.2,0.8,0.2,1, duration: 0.5))`; clamp progress monotonically upstream so it can never run backward. Do not rotate the glyph at runtime.
- Pulsing dot on `Arrived` only: 1.6s ease-in-out, opacity 1 → 0.35. Everything else is static (Live Activities are budget-limited).

---

**Files:** `la/la-data.jsx` (states as data — port the strings from here) · `la/la-kit.jsx` (the five parts + four surfaces) · `la/la-board.jsx` (review board) · `Live Activity.html`.
