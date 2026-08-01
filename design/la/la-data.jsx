// Live Activity + Dynamic Island — the state machine, as data.
// One row per state the widget can render. This mirrors RideActivityCopy
// on the client; every string here is a client-side string.

const LA_VEHICLE = 'Cybercab';
const LA_PICKUP = 'Sansome & Clay';
const LA_DEST = "Duarte's Tavern";

// chip tones — map to tokens, not new colors
const LA_TONE = {
  pending:  { c: T.goldDeepSoft, label: 'pending' },
  active:   { c: T.gold,         label: 'active' },
  riding:   { c: T.driving,      label: 'in ride' },
  done:     { c: T.parked,       label: 'complete' },
  dead:     { c: T.offline,      label: 'terminal' },
};

const LA_STATES = [
  {
    id: 'requested', label: 'Requested', group: 'live',
    note: 'Not in the shipped matrix — proposed. The chip exists but no headline was specified.',
    proposed: true,
    headline: { kind: 'sentence', text: LA_VEHICLE + ' is on its way to you' },
    second: { pickup: true },
    track: null, chip: 'Requested', tone: 'pending',
    compact: { text: 'Sent', tone: 'pending' },
  },
  {
    id: 'accepted-eta', label: 'Accepted · ETA + progress', group: 'live',
    note: 'The hero state. One type size across the headline; the unit carries the meaning, so a duration can never be misread as a clock time. Under a minute the value becomes seconds ("45 s").',
    headline: { kind: 'countdown', prefix: 'Pick up in', value: '4', unit: 'min' },
    second: { pickup: true },
    track: { p: 0.38, leg: 1 }, chip: 'On the way', tone: 'active',
    compact: { text: '4 min', tone: 'active' },
  },
  {
    id: 'accepted-noeta', label: 'Accepted · no ETA', group: 'live',
    note: 'Sentence headline. No track at all — never an empty rail.',
    headline: { kind: 'sentence', text: LA_VEHICLE + ' is coming to pick you up' },
    second: { pickup: true },
    track: null, chip: 'On the way', tone: 'active',
    compact: { text: 'Coming', tone: 'active' },
  },
  {
    id: 'arrived', label: 'Arrived', group: 'live',
    note: 'Track is full on the server’s authority, not from an ETA.',
    headline: { kind: 'sentence', text: LA_VEHICLE + ' is here' },
    second: { pickup: true },
    track: { p: 1, leg: 1 }, chip: 'Arrived', tone: 'active', pulse: true,
    compact: { text: 'Here', tone: 'active' },
  },
  {
    id: 'enroute-eta', label: 'En route · ETA', group: 'live',
    note: 'Leg flip resets the rail to zero and swaps the second line from the pickup to the destination — one place, in gold.',
    headline: { kind: 'countdown', prefix: 'Arriving in', value: '17', unit: 'min' },
    second: { trip: true }, track: { p: 0.52, leg: 2 }, chip: 'In ride', tone: 'riding',
    compact: { text: '17 min', tone: 'riding' },
  },
  {
    id: 'enroute-noeta', label: 'En route · no ETA', group: 'live',
    note: 'Sentence + destination. Rail shown only if progress is present.',
    headline: { kind: 'sentence', text: LA_VEHICLE + ' is taking you there' },
    second: { trip: true }, track: { p: 0.52, leg: 2 }, chip: 'In ride', tone: 'riding',
    compact: { text: 'Driving', tone: 'riding' },
  },
  {
    id: 'stale', label: 'Stale · pushes stopped', group: 'live',
    note: 'Countdown replaced by the status sentence + dated notice. Rail keeps its position, loses its gold; the compact island keeps the last known figure at 45%.',
    headline: { kind: 'sentence', text: LA_VEHICLE + ' is taking you there' },
    second: { trip: true }, track: { p: 0.52, leg: 2 }, chip: 'Not updating', tone: 'dead',
    stale: 'Last update 4:02 PM',
    compact: { text: '17 min', tone: 'stale' },
  },
  {
    id: 'completed', label: 'Completed', group: 'end',
    // MYR-405 (client, 2026-07-31): the linger is FIVE minutes, not fifteen. The
    // end policy is the lifecycle worker's; what this row owns is unchanged —
    // full rail, arrow parked on the cap.
    note: 'Lingers ~5 min. Full rail, arrow parked on the destination cap — the only arrival beat.',
    headline: { kind: 'sentence', text: "You've arrived at " + LA_DEST },
    second: null, track: { p: 1, leg: 2 }, chip: 'Dropped off', tone: 'done',
    compact: { text: 'Done', tone: 'done' },
  },
  {
    id: 'declined', label: 'Declined', group: 'end',
    note: 'No second line, no rail. Chip carries the whole outcome.',
    headline: { kind: 'sentence', text: LA_VEHICLE + " can't take this ride" },
    second: null, track: null, chip: 'Declined', tone: 'dead',
    compact: { text: 'Ended', tone: 'dead' },
  },
  {
    id: 'cancelled', label: 'Cancelled', group: 'end',
    note: 'Subject-free sentence — the rider may be the one who cancelled.',
    headline: { kind: 'sentence', text: 'This ride was cancelled' },
    second: null, track: null, chip: 'Cancelled', tone: 'dead',
    compact: { text: 'Ended', tone: 'dead' },
  },
  {
    id: 'expired', label: 'Reservation expired', group: 'end',
    note: 'Longest chip in the set — sets the chip’s max width.',
    headline: { kind: 'sentence', text: LA_VEHICLE + " didn't make it in time" },
    second: null, track: null, chip: 'Reservation expired', tone: 'dead',
    compact: { text: 'Ended', tone: 'dead' },
  },
  {
    id: 'unknown', label: 'Unknown status · fallback', group: 'end',
    note: 'Never ships intentionally. Chip reads "Ride"; headline falls back to the vehicle line.',
    proposed: true,
    headline: { kind: 'sentence', text: LA_VEHICLE + ' ride in progress' },
    second: null, track: null, chip: 'Ride', tone: 'dead',
    compact: { text: 'Ride', tone: 'dead' },
  },
];

Object.assign(window, { LA_STATES, LA_TONE, LA_VEHICLE, LA_PICKUP, LA_DEST });
