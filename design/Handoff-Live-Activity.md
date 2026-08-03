# Handoff · Live Activity & Dynamic Island

Rebuilt against the 1.0.0 field report (build `202608010021`, iPhone 18,2 / iOS 26.5.2), with the **Uber ride Live Activity as the structural and copy reference** — that was the team's call. Board: `Live Activity.html`. States as data: `la/la-data.jsx` — port strings from there.

The state machine is unchanged. What each state renders, and every rider-facing string, changed.

> Mirror note (2026-08-01): synced from the design project after the §0 change request.
> Standing client decisions that OVERRIDE prose below where they conflict:
> completed linger = 5 minutes (MYR-405/406); ETA figures hold the last pushed value
> statically — no local countdown (client ruling; also matches measured ActivityKit
> behavior: periodic timelines do not tick between content updates). Implementation
> constants live in RideActivityMetrics; §0's shipped corner-safe insets:
> expandedCornerSafeHorizontal 6pt · expandedCornerSafeTop 4pt · expandedRailCornerSafeInset 6pt.
> Platform trap (measured, PR #168): `.contentMargins` on a DynamicIslandExpandedRegion
> compiles and is silently dropped — `.padding` is the only mechanism that reaches
> that surface.
>
> **Mirror note (2026-08-02, MYR-412) — THE CORRECTED READING OF THE BOARD, and it
> overrides the "Center —" line in §Minimal & compact, §0 B's table and §9's compact
> paragraph wherever they conflict.** The client sent the board image to settle it,
> against build `202608011648`. On the **la-board "ENROUTE · NO TELEMETRY" mock** the
> compact island is: **LEADING** = the east arrow (as shipped), **TRAILING** = a
> **BARE ring** — solid track, partial gold arc, **nothing inside it**. Three
> corrections follow, and all three are about the two BARE surfaces (the compact
> trailing half-pill and the expanded `.trailing` region). **The MINIMAL island keeps
> its centre content** — §5's "ring d24 · center arrow 12 / glyph 13" stands there,
> and it is the one surface where the mark inside the ring is the only thing saying
> whose ride this is.
>
> 1. **The wave and the check render BARE** — no ring drawn around them
>    (*"why is there a circle around the hand thats not needed"*). Sizes: wave 17
>    compact / 19 expanded, check 15 compact / 17 expanded, both white, both inside
>    the ranges §5 and §9 give (wave 17-19, check 15-19); the check is the smaller of
>    each pair because a filled disc carries more ink per point than an open hand.
> 2. **The no-telemetry ring is a bare LOADING ring** — *"it should just be a loading
>    icon bc no data from telemetry was found"*. Solid track (white 20%), partial gold
>    arc (~25-35%; shipped at §0 B's own 25%), round cap, from 12 o'clock, no arrow and
>    no glyph in the middle. **This retires PR #168's dashed full ring**, which was a
>    deduction (a static quarter arc is pixel-for-pixel `ringDeterminate(0.25)`) the
>    client overruled with the mock in hand.
> 3. **Left clipping is fixed by an inset on the compact trailing slot.** Cause,
>    measured on #168: `Circle().stroke` centres the line on the path, so a ring in a
>    22pt frame draws to 24.2pt and the compact trailing region — which clips on the
>    HORIZONTAL axis and not the vertical — shaved the outer 1.1pt off each side. The
>    ring's ink measured **23.00 × 24.67pt** where an unclipped one measures 24.2 in
>    both axes. `compactTrailingInset` = 4pt (must exceed the 1.1pt overhang; the rest
>    is clear space). The ETA FIGURE is deliberately not inset, so §0 D's
>    byte-identity promise for Enroute / Arriving / On-trip / Stale still holds.
>
> **MOTION VERDICT, MEASURED (MYR-412): nothing available on this surface animates
> the waiting ring, INCLUDING SF Symbol effects.** §0 B's `repeatForever` rotation was
> already known not to run. Symbol effects are a different mechanism, so they were
> tested rather than assumed: `progress.indicator` with
> `.symbolEffect(.variableColor.iterative.reversing)`, `ellipsis` with
> `.symbolEffect(.variableColor.iterative)` and `arrow.trianglehead.clockwise` with
> `.symbolEffect(.rotate)` (iOS 18+) were rendered in this very slot on a live
> Activity. All three DRAW; none moves — 12 frames ~130ms apart over 1.52s plus a
> 10-frame run a minute earlier, every pair `ImageChops.difference` bbox `None`, max
> delta 0, including across the two runs. Every spoke of `progress.indicator` renders
> at full opacity, which is `.variableColor`'s inert base state. So the loading ring
> ships STATIC, exactly as the mock draws it. The 1.4s rotation is left applied and
> costs nothing.

> **Mirror note (2026-08-02, MYR-417) — TWO CLIENT-DIRECTED CHANGES, one to §8's
> Dispatch row and one to the loading ring's MOTION VERDICT. Both override the prose
> below where they conflict.**
>
> 1. **DISPATCH IS `Ride requested from {car}` / `{plate} · {color} {year} {model}` —
>    a deliberate deviation from this board's Uber copy.** §8 row 1 reads `Finding
>    your ride` / `Matching you with a ride`, and la-data's note says "no car assigned
>    yet, so there is no ETA, no progress and no plate to show". **That is true of a
>    hailing product and false of this one.** A MyRoboTaxi rider picks ONE specific
>    car by name and the request goes to that car's owner; nothing is searched for and
>    nothing is matched. The client, verbatim: *"when ride requested it should say ride
>    requested from {car name}, Plate - Model/Trim/year how we have it in the ride
>    states."* So the headline names the car and the subline is the SAME vehicle
>    descriptor rows 2-6 carry — the plate and the model ARE known at dispatch, off the
>    same `GET /api/vehicles` row the static vehicle attribute is read from. Nameless
>    car → `Your Tesla`, this board's own rule. **The rail is unchanged (idle at 0) and
>    both island slots are unchanged (the ring).** Measured at 20/600 in the card's
>    320pt row: `Ride requested from Your Tesla` 271.4pt, `…Blue Whale` 280.3pt,
>    `…Alex's Model 3` 310.0pt — and 261.4 / 269.7 / 298.4pt at the island's 19/600.
>    A nickname past ~14 characters ellipsizes, which is safe here and nowhere else on
>    the card: the tail of a name the rider chose is the least load-bearing thing on
>    the surface, and the full identification is on the line directly beneath it.
>
> 2. **⚠️ THE LOADING RING MOVES NOW, AND §0 B's "the platform will not run it" WAS
>    TOO GENERAL A CONCLUSION.** Both earlier measurements stand — `repeatForever`
>    armed from `onAppear` is inert (#168), and SF Symbol effects are inert (MYR-412) —
>    but both are about animations the APP arms, and a Live Activity's view is rendered
>    out of process where none of those run. **The system's own timer-driven elements
>    are not animations**: they carry a date range and the renderer re-derives them.
>    `Text(timerInterval:)` is the known one; **`ProgressView(timerInterval:countsDown:)`
>    in the `.circular` style is a RING**, and that is what the indeterminate state now
>    draws — over a rolling `now … now+90s` window restarted by every content-state
>    update, gold-tinted, bare.
>    - **MEASURED ON A LIVE ACTIVITY IN THAT SLOT** (iPhone 17 Pro, iOS 26.5): bright
>      gold ink **116 → 192 → 270 → 348 px** across four frames 6s apart.
>    - **A CUSTOM `ProgressViewStyle` OVER THE SAME `ProgressView` IS INERT** —
>      `configuration.fractionCompleted` is `nil` there, so it draws its floor arc and
>      never moves (measured side by side in one frame). **The moment the ring's
>      geometry becomes ours the motion stops being the system's**, which is why this
>      ships as the stock style with a tint rather than as the board's `Circle().trim`.
>    - **The two empty labels are load-bearing.** The default composition puts a timer
>      TEXT in the ring's middle ("0:27"); `.labelsHidden()` does not remove it,
>      supplying `label:`/`currentValueLabel:` as `EmptyView()` does, and the arc keeps
>      moving. The result is this board's bare ring exactly.
>    - **What the stock style costs**, stated rather than glossed: the stroke is the
>      system's (2.0pt measured inside a 22pt frame, against the board's 2.2) and the
>      TRACK is the tint at ~35% (rgb 70,59,27) where the board's is white 20%
>      (rgb 51,51,51). The ARC is `#C9A84C` exactly, round-capped, from 12 o'clock.
>    - **Reduce Motion falls back to MYR-412's static arc** — byte-identical frames
>      (bbox `None`, max delta 0) — and `ringSpin`'s dead `repeatForever` is DELETED
>      rather than "kept applied in case": a mechanism measured inert twice is not a
>      promise, and the promise now has a real implementation.
>    - **DETERMINATE PROGRESS AND TRACK-ONLY ARE UNTOUCHED.** Only the indeterminate
>      mode moves, on all three surfaces that draw it.

> **Mirror note (2026-08-02, MYR-420) — ⚠️ THE RING IS REMOVED FROM THE ISLAND
> ENTIRELY. CLIENT-DIRECTED, AND IT OVERRIDES §0 B, MYR-412's items 1-2, MYR-417's
> item 2 and §5's "Minimal … ring d24" wherever they conflict.**
>
> **THE RULING, VERBATIM:** *"remove the ring entirely then and if theres data it
> appears on the right side."* It was given after the measurement below established
> that the spinner he asked for cannot be built on this surface at any rate, and
> after he was offered the only two real alternatives — MYR-417's ring that moves but
> reads as progress, and MYR-412's static arc that is correct and dead. He took
> neither.
>
> **THE NEW RULE, ON EVERY ISLAND SURFACE — `figure > arrival glyph > EMPTY`:**
>
> | rung | what renders | where |
> |---|---|---|
> | 1 | the ETA figure (`8 min` / `1 min` / `3:42 PM`, 15/600 tabular) | COMPACT trailing only |
> | 2 | the arrival glyph — `hand.wave.fill`, `checkmark.circle.fill`, bare, white | compact (17/15), expanded (19/17), minimal (13) |
> | 3 | **nothing at all** | everywhere else |
>
> - **TEN OF THE FOURTEEN ROWS NOW RENDER AN EMPTY TRAILING HALF-PILL** beside the
>   mark — Dispatch, both no-ETA rows, no-telemetry, and all four endings. **That is
>   the design, by decision.** §0 B raised the ring precisely because this frame
>   "reads like an app that has stopped working"; the client has seen it and chosen
>   it over the two rings that were available, and that is not a judgement for an
>   implementer to re-litigate.
> - **THE MINIMAL ISLAND IS THE MARK ALONE.** MYR-412 kept the ring there on the
>   reading that a BARE ring would be an anonymous circle; with no ring anywhere, what
>   is left is §5's CENTRE — the east arrow at 12, swapping for the arrival glyph at
>   13. That is exactly what v3 shipped before §0 B.
> - **NOTHING ELSE MOVES.** The lock-screen card is untouched in every state, and so
>   is the expanded island's BOTTOM RAIL. **The rail is where this surface says how
>   far along a ride is** — it always was, the ring only ever drew the rail's own
>   fraction, and the four rows whose slot went empty keep exactly the rail they had.
>   The ETA figures and the two arrival glyphs are byte-identical to the shipped
>   build, including `compactTrailingInset` = 4, which survives as the GLYPH's clear
>   space (its stroke-overhang justification went with the ring, and `strokeOverhang`
>   is deleted).
> - **DELETED IN THE APP:** the whole `RideActivityProgressRing` / waiting-ring / arc
>   component (the file is now `RideActivityTrailingSlot.swift` and holds the glyph
>   rule alone), the `.ringDeterminate` / `.ringIndeterminate` / `.ringTrackOnly`
>   cases with `RideActivityCard.ring(for:rail:)`, the ring's ten metrics, the
>   `arrivalRing*` half of the §0 C beat, and the `mrtActivityRingTrack` token. **The
>   empty rung is an enum CASE, not an invisible ring**, so no state can resolve to
>   one however the ladder is edited later.
>
> **THE MEASUREMENT THAT MADE THE ASK IMPOSSIBLE IS KEPT BELOW, VERBATIM AND
> DELIBERATELY**, because it is the reason there is no spinner AND now no ring, and
> the app no longer has a file of its own for it to live beside. The next person told
> "make this move" needs it before they spend a round re-testing a candidate that has
> already been photographed dead.
>
> The client on MYR-417's timer ring: *"The loading icon should just be a ring
> spinning not slowly filling. It essentially means we're waiting for live data."*
> The objection is exact — a ring that creeps 0 → 100% over 90s IS the determinate
> ring's own grammar, so the one state that means "the car has told us nothing" is
> drawn in the vocabulary of "here is how far along you are".
>
> - **⚠️ THE PLAIN INDETERMINATE `ProgressView()` + `.progressViewStyle(.circular)`
>   IS DEAD, AND IT IS NOT EVEN DRAWN AS A SPINNER.** It was the one candidate the
>   MYR-417 matrix had not tried, and it was a fair hypothesis: the timer ring proves
>   this surface runs SOME stock `ProgressView` behaviour, so the indeterminate one
>   was worth a frame rather than an assumption. Rendered in this very slot on a live
>   Activity (iPhone 17 Pro, iOS 26.5, `MRT_ACTIVITY_STATE=noTelemetry`): **there are
>   no spokes.** WidgetKit resolves the indeterminate circular style to an EMPTY GAUGE
>   RING — the tint at ~35%, i.e. pixel-for-pixel the track the ended states already
>   draw — and it never moves. Lossless `simctl io` frames: **5 frames 12s apart
>   (48s span) `ImageChops.difference` bbox `None`, max delta 0, gold ink 185 px in
>   every one**; and 6 frames 3s apart, same verdict. `.fixedSize()` (in case the
>   22pt parent frame was clamping a spinner) renders **byte-identically** — same
>   185 px — so the frame was never the reason.
> - **THE CONTROL IS THE SAME SLOT IN THE SAME BUILD.** Swapping only the
>   initializer back to `ProgressView(timerInterval:)` moves it: gold ink
>   **297 → 457 → 618 → 775 → 935 px** across the identical five frames. So the rig
>   sees motion, the island does re-render, and the difference is the candidate.
> - **THE EXPANDED `.trailing` REGION AGREES** — long-pressed via SpringBoard, two
>   frames 6s apart, the whole island band diffs bbox `None`, max delta 0. MINIMAL is
>   unphotographable as always (two Activities of one app still render one compact
>   pill), and it is the same component in the same process.
> - **THE REUSABLE RULE, WHICH IS THE POINT OF THIS NOTE: A SELF-UPDATING ELEMENT ON
>   THIS SURFACE IS A RAMP OVER A DATE RANGE, AND A RAMP CANNOT REPEAT.** The
>   platform's whole set of elements the renderer re-derives out of process is the
>   dynamic-date family — `Text(.timer)` / `Text(timerInterval:)` /
>   `Text(_, style:)` — plus `ProgressView(timerInterval:)`. Every one of them is a
>   monotone function of the clock over a range that is fixed when the frame is
>   composed. **A spinner is a REPEATING clock**, and the only thing that can arm one
>   is the app, whose animations are not run here (§0 B `repeatForever`, MYR-412
>   symbol effects, both still inert). So the honest ceiling is: this surface can
>   fill, drain, or travel **once** per push interval (60–90s) — it cannot spin at
>   any rate a person would read as spinning.
> - **WHAT WAS PUT TO THE CLIENT, AND WHAT HE ANSWERED.** The two things that could
>   replace the timer-fill ring were MYR-412's static arc (which is the complaint the
>   fill was raised to answer) and a fake — and a fake is worse than either. The
>   choice between "moves but reads as progress" and "correct but dead" was his to
>   make, and **he made a third one: remove it.** See the head of this note.

---

## 0 · Change request for this build — three items

Everything below §1 is the full spec. These three are what is **wrong in the shipped
build** and what to pick up next. Written to be actionable on their own.

### A · Fix the expanded Dynamic Island sizing

**Symptom:** the expanded island is a tall black box with content crowded at the
top and a large empty field below and to the right.

**Cause:** wide content is being placed in the top row. The sensor housing splits
that row — only a narrow leading and a narrow trailing region survive there — so
the system pushes anything wide around the housing and pads the difference. A
fixed `.frame(height:)` or a `Spacer()` makes it worse.

**Fix:** move every wide element into `.bottom` and keep the top row to two small
things. Do not set a width or a height anywhere in the expanded builder.

```swift
DynamicIsland {
  DynamicIslandExpandedRegion(.leading)  { BrandMark(size: 26) }
  DynamicIslandExpandedRegion(.trailing) { TrailingSlot(state: ctx.state) }  // glyph or nothing (MYR-420)
  // .center intentionally unused — the housing owns it
  DynamicIslandExpandedRegion(.bottom) {
    VStack(alignment: .leading, spacing: 2) {
      Headline(ctx.state)            // 19 / semibold
      Subline(ctx.state)             // 12.5 / 58% white
      RouteRail(ctx.state).padding(.top, 8)
    }
  }
}
```

Acceptance: no empty right half in any state, no empty band under the rail, and
the island's height differs between a two-line and a three-line state (proof
nothing is pinned).

### B · The loading ring — what to show when there is no data

The mark alone is not information. Give the empty slot a 24pt ring (22pt in the
compact trailing slot) that carries the leg's progress. One component, three states:

> ⚠️ **MYR-412: "wrap it" was read as "put the mark inside it" and that is wrong for
> two of the three surfaces.** The ring is BARE in the compact trailing slot and in
> the expanded `.trailing` region — the board's mock has nothing in its middle. Only
> the MINIMAL island wraps the mark. See the mirror note at the top.

| Condition | Ring | Meaning to the rider |
|---|---|---|
| telemetry flowing | gold arc = `rail.p`, animates to each new value over 0.5s | how far along this leg is |
| route known, **no telemetry yet** | a **25% arc** (designed to rotate at 1.4s linear; ships static — MYR-412) | connected and working, just no position yet |
| ride ended (declined / cancelled / expired) | track only, no arc | nothing left to progress |

The rotation is the whole point of item B: it is the difference between "the app
is dead" and "we are waiting on the car," and it costs nothing but a repeating
rotation on a static shape.

> ⚠️ **MYR-412 (measured, twice, two mechanisms): the platform does not run it.**
> `repeatForever` armed from `onAppear` was measured inert in PR #168, and the
> follow-up ruled out the other candidate — SF Symbol effects
> (`.variableColor.iterative[.reversing]` on `progress.indicator` / `ellipsis`, and
> `.symbolEffect(.rotate)` on `arrow.trianglehead.clockwise`) all render their inert
> base state and never move: 22 frames across two runs a minute apart, bbox `None`,
> max delta 0. The ring is still the difference between a dead app and a waiting one
> — the ARC is, not the rotation.

```swift
Circle().trim(from: 0, to: 0.25)
  .stroke(Color.mrtGold, style: .init(lineWidth: 2.4, lineCap: .round))
  .rotationEffect(.degrees(spin))
  .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spin = 360 } }
```

Budget note: this is a **view-local** animation, not a push. It does not consume
Live Activity update budget. Determinate progress DOES come from a push — animate
`trim(to:)` with `.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)` so it sweeps to
the new value instead of jumping.

### C · Animate the check at drop-off

Completion is the one moment the widget should feel like it landed. When the
server sends the completed state, the ring is already full — so it hands off to
the check rather than both being drawn at once.

1. Ring completes to 100% (0.5s, same curve as any progress update).
2. Ring fades to 40% and the **check scales in from 0.6 → 1.0** with
   `.spring(response: 0.34, dampingFraction: 0.72)`, 0.1s after the ring lands.
3. Nothing repeats. One beat, then static — it lingers ~15 min and must not
   animate for that whole time.

```swift
Image(systemName: "checkmark.circle.fill")
  .scaleEffect(landed ? 1 : 0.6).opacity(landed ? 1 : 0)
  .animation(.spring(response: 0.34, dampingFraction: 0.72).delay(0.1), value: landed)
```

### D · The ring is a fallback, never a replacement

To be unambiguous, because this is easy to over-apply: **the ETA still wins.** The
trailing slot of the compact island resolves in strict priority order — (1) the ETA
figure if the server has one, so `8 min`, `1 min` and `3:42 PM` render exactly as
they do today and nothing about Enroute, Arriving, On trip or Stale changes; (2)
the arrival glyph at the two stops, wave and check; (3) the progress ring **only
when there is neither**, which is Dispatch, both no-ETA states, no-telemetry, and
the ended states. The ring is not a new default and it never displaces a number —
it fills a slot that was previously an empty half-pill. Same rule in the expanded
island's `.trailing` region, except the ETA is excluded there too (the expanded
headline already carries it), so that slot is glyph-or-ring.

---

## 1 · The six things the report called out

| # | Report | Fix | Cost |
|---|---|---|---|
| 1 | *"It's saying arriving while on the way to the destination"* | **The two legs use two different headline forms**, as Uber does. Pickup leg counts down: `Pickup in 8 min`. Trip leg states a clock time: `3:42 PM dropoff`. A duration can never be read as a time of day, and **"Arriving" is retired** from rider-facing copy. | Copy |
| 2 | *"Always show the route line, even without telemetry"* | **The rail is unconditional.** No telemetry = rail at zero, filling in as data lands. Never a missing row. | Layout |
| 3 | *"Line to pickup → finished at pickup → restart → finished at dropoff"* | **One rail per leg**, exactly that sequence. The leg flip is the only event allowed to send progress backward. | Layout |
| 4 | *"All banners the same width and height"* | **350 × 128 in every state**, four fixed-height rows. Terminal states keep the rail (idle) rather than collapsing. | Layout |
| 5 | *"The Island should expand at every state transition"* | All **six phase changes ship an alert configuration** → iOS expands the island ~3s, then collapses to compact itself. | Client |
| 6 | *"Expanded Island is a lot of black space"* | Two rows, height driven by content. See §Expanded regions — the shipped build put wide content in the top row, which the sensor housing forces the system to pad around. | Layout |
| 7 | *Minimal shows only the logo* | Minimal now wears the **leg progress as a ring** around the mark, and spins a 25% arc when telemetry has not landed. Useful at 24pt, no text. | Layout |

---

## Expanded regions — read before touching the layout

The expanded island is **not** a free canvas. The sensor housing splits the top;
only a narrow leading and trailing region survive there. Anything wide placed in
the top row gets pushed around it, and the system pads the difference — that is
the black space in the report.

| Region | Contents | Notes |
|---|---|---|
| `.leading` | brand mark, 26pt | nothing else |
| `.trailing` | the arrival glyph (wave / check) when there is one, else the **progress ring** at 24pt | never the ETA — the headline already carries it, and repeating it is the clutter the report named. Never empty either. |
| `.center` | **empty** | do not use it |
| `.bottom` | headline 19/600 → subline 12.5 → rail | full width lives here |

No fixed `.frame(height:)`, no `Spacer()` padding the column. Height follows the
content — do not pin it. Width is the system's (screen − 20pt each side) — do not
set that either.

Corner-safety (shipped values, PR #168): content adjacent to the pill's corner
curvature carries targeted insets — top-row regions 6pt horizontal + 4pt top; the
rail 6pt at both ends. `.padding` only; `.contentMargins` is silently dropped on
this surface.

---

## Minimal & compact — the progress ring

One ring component, two sizes: 24pt centered in **minimal**, 22pt in the
**compact trailing** slot whenever there is no figure and no glyph. Stroke 2.4
(2.2 compact), track white 20%, progress `mrtGold`, round cap, starting at 12
o'clock. The compact pill is never a half-empty black lozenge again.

- **Determinate** — arc = `rail.p` for the current leg. Same number the card's rail draws, so the two surfaces never disagree. Floor it at 2% so the cap is always visible.
- **Indeterminate** — a 25% arc, whenever the route is known but no telemetry has landed (`rail.state == .idle` on a live ride). Reads as "working," which is true, instead of a dead logo. (⚠️ **Corrected by MYR-412** — see the mirror note at the top. It was designed to rotate at 1.4s linear and **nothing on this surface will turn it**: not `repeatForever`, not an appearance-armed animation, and not an SF Symbol effect, all measured. It ships as the STATIC partial arc the board draws; #168's interim dashed full ring is retired.)
- **Track only** — ended rides (declined / cancelled / expired). Nothing to progress.
- **Center** — ⚠️ **MINIMAL ONLY, corrected by MYR-412.** On the minimal island: the east arrow, swapped for the arrival glyph at 13pt in Arrived and Completed. On the **compact trailing** slot and the expanded `.trailing` region the ring is **BARE** and the arrival glyph replaces it rather than sitting inside it — the board's own reading, and the client's *"why is there a circle around the hand thats not needed"*.

---

## 2 · What we took from Uber

- **Wordmark alone on the top row** — and nothing else. **No badges anywhere on the card.** Every state says what it is in words: the headline carries the status, the subline carries the detail. A pill repeating the headline is noise.
- **The headline leads and is bold** (20/600). It is the first thing read, and the largest thing on the card.
- **The subline carries what that leg needs.** `7SRJ294 · Silver Model Y` while the car is coming — the same string Uber puts in the same slot — then `Heading to Duarte's Tavern` once you're in it. Never a status.
- **The rail is unlabeled.** The subline names the destination, so labels under the rail were redundant — they're gone.
- **Two ETA forms, one per leg.** Countdown to pickup, clock time to dropoff. This is the actual fix for the report's first complaint.
- **No trailing tile.** Uber's is a driver photo; a driverless car has no driver, and we have no vehicle render yet. The slot stays **empty** rather than being filled with a stylized plate badge — the plate is plain text in the subline, which is where Uber also puts it. If a render lands later, that slot is 58–62 × 38–40.
- **Uber's phase names** for engineering: `Dispatch → Enroute → Arriving → Arrived → On trip`. "Arriving" is fine as a phase name; it is never a rider-facing string.
- **Uber's compact-island rule:** a figure, never an invented status word. Ours shows `8 min` / `1 min` / `3:42 PM`, a wave at the pickup and a check at completion — and where Uber would show the mark alone, we show the mark plus the progress ring, so the slot always carries something true.

## 3 · The four rows

Fixed heights, `space-between`. Nothing a state does can change the footprint.

1. **Wordmark row · 20pt** — logo 20, wordmark 10/500 uppercase @42%. Nothing trailing.
2. **Headline · 24pt row** — 20/600, one line. `{Phase} in {n} {unit}` · `{h:mm A} dropoff` · or a status phrase.
3. **Subline · 17pt row** — 13.5/400 @58%, one line, ellipsis. Plate + car on the pickup leg, destination on the trip leg. The plate is *not* stylized — no badge, no box.
4. **Route line · 18pt** — always drawn, **always gold**. 5pt track, gold fill, brand arrow (14) in a 22pt `#0d0b06` puck riding the head, 11pt destination pin. At `p = 1` the pin is removed and the mark stands in its place — the car has become the marker.

Trailing the headline+subline block: **nothing** — the plate is plain text in the subline. If a vehicle render lands later, that slot is 58–62 × 38–40.

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
Minimal      37 × 37 · ring d24 stroke 2.4 · center arrow 12 / glyph 13
Compact      h 37 · min-w 126 with a figure, 92 without · padding 0 12
             mark 16 leading · trailing: figure 15/600 · glyph 19 · or ring d22
             MYR-412: trailing content is BARE and inset 4 per side (not the
             figure). Shipped glyphs wave 17 / check 15 here, 19 / 17 expanded.
Expanded     r 38 · padding 10/20/15 · gap 10 · top row 34 · logo 26
             headline 19/600 · width + height owned by the system
             corner-safe insets: top-row 6h/4t · rail ends 6 (see Expanded regions)
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
| Dispatch | `Finding your ride` | `Matching you with a ride` | 0 · idle | ring (indeterminate) |
| Enroute | `Pickup in {n} min` | `{plate} · {color} {model}` | live | `{n} min` |
| Arriving | `Pickup in 1 min` | `{plate} · {color} {model}` | live ~90% | `1 min` |
| Enroute · no ETA | `Pickup soon` | `{plate} · {color} {model}` | live | ring (determinate) |
| Enroute · no telemetry | `Pickup soon` | `{plate} · {color} {model}` | 0 · idle | ring (indeterminate) |
| Arrived | `Your ride is here` | `{plate} · {color} {model}` | 1 · live | wave |
| On trip | `{h:mm A} dropoff` | `Heading to {place}` | live | `{h:mm A}` |
| On trip · no ETA | `Dropoff soon` | `Heading to {place}` | live | ring (determinate) |
| Pushes stopped | `Dropoff soon` | `Last updated {h:mm A}` | hold · live | last figure |
| Completed | `You've arrived` | `{place}` | 1 · live | check |
| Declined | `No ride available` | `Nothing was charged` | 0 · idle | ring (track only) |
| Cancelled | `Ride cancelled` | `Nothing was charged` | 0 · idle | ring (track only) |
| Reservation expired | `Reservation expired` | `No car arrived in time` | 0 · idle | ring (track only) |
| Unknown *(fallback)* | `Ride in progress` | `Tap to open MyRoboTaxi` | 0 · idle | ring (track only) |

**Chips appear only when the headline can't say it** — they don't, anywhere. Removed from every surface.

## 9 · SwiftUI notes

- **Auto-expand.** Push each phase change with an alert configuration on the content update, which is what makes the island expand and then collapse itself. Alert on the six phase changes only — `Dispatch → Enroute → Arriving → Arrived → On trip → Completed`. Do **not** alert on ETA ticks or the stale flip, or the island strobes.
- **Fixed card height.** `.frame(height: 128)` on the Lock Screen view and a fixed `.frame(height:)` per row. Headline and subline are `lineLimit(1)` + `.truncationMode(.tail)` in every state — never let a `Text` grow the stack.
- **Card ground is a real `ZStack` of the two gradients**, not `.ultraThinMaterial`; the glass was the system default, not a choice. The island stays true black — hardware.
- **ETA figures hold the last pushed value** (client ruling; supersedes any timer note): derived once per content-state update, `{n} min` / `{n} s`, never mm:ss.
- **Trip dropoff time** is a formatted `Date`, not a timer: `.formatted(date: .omitted, time: .shortened)`, recomputed only when the server sends a new ETA. It does not tick.
- **Rail.** One `GeometryReader`; animate fill width and the puck `.offset` with `.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)`. **Clamp puck travel to the track** — `11 + (width − 22) * p` — so it never overhangs the end, and **hide the destination pin at `p = 1`** so the mark occupies that spot alone; two markers stacked on the same point reads as a rendering bug. The arrow is a fixed asset rotated 90° from the mark — never rotate it at runtime.
- **Compact trailing is a figure, a glyph, or the ring.** `8 min` · `1 min` · `3:42 PM`, exactly as Uber does it — never an invented status word. At the two stops it is a glyph instead: a **wave** at the pickup — same beat as Uber's, the car greeting you — and a **check** at completion, both white, 19pt, from the icon font (ship the SF Symbols). With neither a figure nor a glyph, the **progress ring** takes the slot (d22 compact, d24 expanded) rather than leaving the pill half empty. **All three are BARE** (MYR-412) — the glyph is not drawn inside the ring and the ring holds nothing; shipped at wave 17 / check 15 compact and wave 19 / check 17 expanded, and the slot carries a 4pt inset per side so a centred stroke is not shaved by the region's own clip.
- **Pulsing dot** — removed. Everything on the card is static; the only motion is the rail interpolating on a real update. Live Activities are budget-limited.

---

**Files:** `la/la-data.jsx` (states + transition list as data) · `la/la-kit.jsx` (four rows + four surfaces) · `la/la-board.jsx` (review board) · `Live Activity.html`.
