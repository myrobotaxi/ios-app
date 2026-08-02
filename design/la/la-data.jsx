// Live Activity + Dynamic Island — the state machine, as data. (v3)
//
// Structure and phrasing follow the Uber ride Live Activity, which is the
// reference the team picked:
//   · Five phases: Dispatch → Enroute → Arriving → Arrived → On trip.
//   · The headline leads and is bold. Pickup leg counts DOWN in minutes
//     ("Pickup in 8 min"); the trip leg states a CLOCK TIME ("3:42 PM
//     dropoff"). Two different forms, so a duration can never be mistaken
//     for a time of day.
//   · The subline is the one piece of context that leg needs: which car is
//     coming ("7SRJ294 · Silver Model Y") on the way to you, where you're
//     going ("Heading to {place}") once you're in it.
//   · The rail is unlabeled — the subline already names where you're going.
//   · The compact island carries a FIGURE or nothing — "8 min", "1 min",
//     "3:42 PM", exactly as Uber does it. No invented status words. At a stop
//     it shows a glyph instead — a wave at the curb, a check when the ride is
//     done — the same non-textual arrival beat Uber uses.
//   · No badges anywhere. Every state says what it is in words — the
//     headline carries the status, the subline carries the detail. The rail
//     is always live gold; it is never dimmed to signal a problem.

const LA_PLATE = '7SRJ294';
const LA_CAR = 'Silver Model Y';
const LA_PICKUP = '1124 Mission St';
const LA_DEST = "Duarte's Tavern";

const LA_STATES = [
  {
    id: 'dispatch', label: 'Dispatch', group: 'pickup', leg: 1, phase: 'Dispatch',
    // ⚠️ MYR-417 (2026-08-02, CLIENT-DIRECTED) — THE SHIPPED COPY FOR THIS ROW IS
    // NOT THIS ROW'S. The note below is Uber's situation, not ours: a MyRoboTaxi
    // rider picks ONE specific car by name, so nothing is being matched and the
    // plate/model ARE known before the request is sent. The client: "when ride
    // requested it should say ride requested from {car name}, Plate - Model/Trim/year
    // how we have it in the ride states." The app therefore renders
    //   headline: 'Ride requested from {car}'   (nameless car -> 'Your Tesla')
    //   sub:      '{plate} · {color} {year} {model}'  — the SAME descriptor rows 2-6
    //                                                   carry, same drop rules
    // The rail (0 · idle) and the compact island (the ring) are UNCHANGED, so this is
    // a copy deviation and nothing else. See the mirror note at the top of
    // Handoff-Live-Activity.md for the measurements.
    note: 'No car assigned yet, so there is no ETA, no progress and no plate to show. The rail still draws, parked at the origin, and the compact island shows the mark alone — exactly what Uber does at Dispatch.',
    headline: { status: 'Finding your ride' },
    sub: 'Matching you with a ride',
    rail: { p: 0, state: 'idle' },
    compact: {},
  },
  {
    id: 'enroute', label: 'Enroute', group: 'pickup', leg: 1, phase: 'Enroute',
    note: 'The hero state. Bold headline leads; the subline is the plate and the car, which is exactly what a rider standing at the curb needs. Uber puts the same string in the same place.',
    headline: { phase: 'Pickup', value: '8', unit: 'min' },
    sub: LA_PLATE + ' · ' + LA_CAR,
    rail: { p: 0.38, state: 'live' },
    compact: { text: '8 min' },
  },
  {
    id: 'arriving', label: 'Arriving', group: 'pickup', leg: 1, phase: 'Arriving',
    note: 'Its own phase under two minutes, exactly as Uber splits it. Same layout, just a smaller number — the rail being nearly full is what signals imminence.',
    headline: { phase: 'Pickup', value: '1', unit: 'min' },
    sub: LA_PLATE + ' · ' + LA_CAR,
    rail: { p: 0.88, state: 'live' },
    compact: { text: '1 min' },
  },
  {
    id: 'enroute-noeta', label: 'Enroute · no ETA', group: 'pickup', leg: 1, phase: 'Enroute',
    note: 'One word swapped in the same slot at the same size — nothing on the card moves, and nothing needs a badge to explain it.',
    headline: { status: 'Pickup soon' },
    sub: LA_PLATE + ' · ' + LA_CAR,
    rail: { p: 0.38, state: 'live' },
    compact: {},
  },
  {
    id: 'enroute-notelemetry', label: 'Enroute · no telemetry', group: 'pickup', leg: 1, phase: 'Enroute',
    note: 'Never blank. The line is the route — true before the first location lands, and it simply fills in as telemetry arrives.',
    headline: { status: 'Pickup soon' },
    sub: LA_PLATE + ' · ' + LA_CAR,
    rail: { p: 0, state: 'idle' },
    compact: {},
  },
  {
    id: 'arrived', label: 'Arrived', group: 'pickup', leg: 1, phase: 'Arrived',
    note: 'Leg 1 complete: rail full, and the mark replaces the destination pin rather than sitting on top of it. The subline still carries the plate — this is the moment the rider needs it most. In the compact island a wave replaces the figure, the same beat Uber uses when the driver pulls up — the car greeting you. Full on the server’s authority, never inferred from an ETA hitting zero.',
    headline: { status: 'Your ride is here' },
    sub: LA_PLATE + ' · ' + LA_CAR,
    rail: { p: 1, state: 'live' },
    compact: { glyph: 'wave' },
  },
  {
    id: 'ontrip', label: 'On trip', group: 'trip', leg: 2, phase: 'On trip',
    note: 'The leg flip resets the rail to zero and changes the form of the headline: a clock time, not a countdown. This is the state that used to read "Arriving in 17 min" — the line the field report was about.',
    headline: { clock: '3:42 PM', word: 'dropoff' },
    sub: 'Heading to ' + LA_DEST,
    rail: { p: 0.52, state: 'live' },
    compact: { text: '3:42 PM' },
  },
  {
    id: 'ontrip-noeta', label: 'On trip · no ETA', group: 'trip', leg: 2, phase: 'On trip',
    note: 'Mirrors the pickup no-ETA state exactly — same slot, same geometry, one word different.',
    headline: { status: 'Dropoff soon' },
    sub: 'Heading to ' + LA_DEST,
    rail: { p: 0.52, state: 'live' },
    compact: {},
  },
  {
    id: 'stale', label: 'On trip · pushes stopped', group: 'trip', leg: 2, phase: 'On trip',
    note: 'The subline carries the timestamp instead of the destination — one honest sentence, no badge and no dimming. The rail holds its last known position and stays gold, because the position is still true; it just is not moving.',
    headline: { status: 'Dropoff soon' },
    sub: 'Last updated 3:31 PM',
    rail: { p: 0.52, state: 'live' },
    compact: { text: '3:42 PM' },
  },
  {
    id: 'completed', label: 'Completed', group: 'end', leg: 2, phase: 'Completed',
    note: 'Lingers ~15 min. Rail full, the mark standing where the destination pin was — the only arrival beat, and the only other state where the rail completes. The compact island shows a check: the ride is done, not merely somewhere.',
    headline: { status: "You've arrived" },
    sub: LA_DEST,
    rail: { p: 1, state: 'live' },
    compact: { glyph: 'check' },
  },
  {
    id: 'declined', label: 'Declined', group: 'end', leg: 2, phase: 'Ended',
    note: 'The route never happened, so the rail is idle at zero rather than absent — the card keeps its height and the row reads as an untraveled route.',
    headline: { status: 'No ride available' },
    sub: 'Nothing was charged',
    rail: { p: 0, state: 'idle' },
    compact: {},
  },
  {
    id: 'cancelled', label: 'Cancelled', group: 'end', leg: 2, phase: 'Ended',
    note: 'Subject-free headline — the rider may be the one who cancelled, so the copy does not assign it.',
    headline: { status: 'Ride cancelled' },
    sub: 'Nothing was charged',
    rail: { p: 0, state: 'idle' },
    compact: {},
  },
  {
    id: 'expired', label: 'Reservation expired', group: 'end', leg: 2, phase: 'Ended',
    note: 'The headline is the outcome; the subline is the reason. Nothing else is needed.',
    headline: { status: 'Reservation expired' },
    sub: 'No car arrived in time',
    rail: { p: 0, state: 'idle' },
    compact: {},
  },
  {
    id: 'unknown', label: 'Unknown status · fallback', group: 'end', leg: 2, phase: 'Ended',
    note: 'Never ships intentionally, but it is reachable. Headline falls back to the vehicle line and the rail goes idle.',
    proposed: true,
    headline: { status: 'Ride in progress' },
    sub: 'Tap to open MyRoboTaxi',
    rail: { p: 0, state: 'idle' },
    compact: {},
  },
];

// The phase changes the island alerts on — Uber's five, plus the end.
// A silent compact swap is unreadable, so each of these expands the island.
const LA_TRANSITIONS = ['dispatch', 'enroute', 'arriving', 'arrived', 'ontrip', 'completed'];

Object.assign(window, { LA_STATES, LA_TRANSITIONS, LA_PLATE, LA_CAR, LA_PICKUP, LA_DEST });
