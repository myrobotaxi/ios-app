// MyRoboTaxi · Anatomy canvas — exploded SCREEN boards.

const { useState: anS } = React;

// Local doc-state wrappers (anatomy page doesn't load ds-screens).
function AHome({ driving }) {
  const [vIdx, setVIdx] = anS(0); const [sheet, setSheet] = anS('peek'); const [nav, setNav] = anS('home');
  return <HomeScreen vehicleIdx={vIdx} setVehicleIdx={setVIdx} sheet={sheet} setSheet={setSheet}
    driving={driving} progress={0.46} battery={68} speed={64} parkedStyle="floating"
    nav={nav} setNav={setNav} mapHeight={874} />;
}
function ADrives() { const [n, sN] = anS('drives'); return <DrivesScreen nav={n} setNav={sN} onOpenDrive={() => {}} driving upcoming={[{ id: 'ou1', rider: 'Mira', dest: { label: 'SFO · Terminal 2', miles: 18.4, mins: 32 }, schedule: { day: 'Tomorrow', time: '6:40 AM' }, vehicle: 'Cybercab' }]} onCancelUpcoming={() => {}} />; }
function AShared() {
  const [rs, setRs] = anS('idle');
  const [dest, setDest] = anS(null);
  return <SharedViewerScreen progress={0.5} battery={68} speed={58} driving={false}
    riderName="Sam" requestState={rs} setRequestState={setRs} requestDest={dest} setRequestDest={setDest}
    requestPassenger={null} setRequestPassenger={() => {}} nav="shared" setNav={() => {}} />;
}
function ATracking() {
  const [rs, setRs] = anS('accepted');
  const [dest, setDest] = anS({ id: 'pescadero', label: "Duarte's Tavern", sub: '202 Stage Rd · Pescadero', miles: 41.2, mins: 87 });
  return <SharedViewerScreen progress={0.5} battery={68} speed={58} driving
    riderName="Sam" requestState={rs} setRequestState={setRs} requestDest={dest} setRequestDest={setDest}
    requestPassenger={null} setRequestPassenger={() => {}} nav="shared" setNav={() => {}} />;
}
function ASummary() {
  const [rs, setRs] = anS('accepted');
  const [dest, setDest] = anS({ id: 'pescadero', label: "Duarte's Tavern", sub: '202 Stage Rd · Pescadero', miles: 41.2, mins: 87 });
  return <SharedViewerScreen progress={1} battery={68} speed={0} driving
    riderName="Sam" requestState={rs} setRequestState={setRs} requestDest={dest} setRequestDest={setDest}
    requestPassenger={null} setRequestPassenger={() => {}} nav="shared" setNav={() => {}} docFreeze />;
}
function ABooking() {
  const [rs, setRs] = anS('pending');
  const [dest, setDest] = anS({ id: 'work', label: 'Work', sub: '88 Marina Blvd · San Francisco', miles: 5.1, mins: 22 });
  return <SharedViewerScreen progress={0.5} battery={68} speed={58} driving={false}
    riderName="Sam" requestState={rs} setRequestState={setRs} requestDest={dest} setRequestDest={setDest}
    requestPassenger={null} setRequestPassenger={() => {}} nav="shared" setNav={() => {}} docFreeze />;
}
function AIncoming() {
  const dest = { id: 'pescadero', label: "Duarte's Tavern", sub: '202 Stage Rd · Pescadero', miles: 41.2, mins: 87 };
  return (<>
    <HomeScreen vehicleIdx={0} setVehicleIdx={() => {}} sheet="peek" setSheet={() => {}} driving={false}
      progress={0.46} battery={68} speed={0} parkedStyle="floating" nav="home" setNav={() => {}} mapHeight={874} />
    <IncomingRequestSheet visible requesterName="Sam" dest={dest} vehicleName="Cybercab" battery={68} kind="now" onAccept={() => {}} onReject={() => {}} />
  </>);
}

// Convenience: phone at fixed spot; anchors are board coords = (PX+sx, PY+sy).
const PX = 320, PY = 64;
const A = (sx, sy) => [PX + sx, PY + sy];

function compactDI() {
  return <DynamicIsland state="compact" vehicle="Cybercab" status="driving" eta={51} battery={68} speed={64} progress={0.46} />;
}

// ── 1 · Live Map · Driving ───────────────────────────────────
function BoardDrivingHome() {
  return (
    <Board w={1120} h={940}>
      <BoardCap kicker="Owner · primary screen" title="Live Map · Driving"
        sub="MapKit base, route overlay, vehicle annotation, and a draggable detent sheet whose hero is the destination + live ETA." />
      <ScreenHost x={PX} y={PY} di={compactDI()}><AHome driving /></ScreenHost>

      {/* Left-side notes */}
      <Note n="1" {...noteL(28, 150)} ax={A(201, 30)[0]} ay={A(201, 30)[1]} title="Dynamic Island"
        lines={[{ t: 'compact · 126×37' }, { t: 'ETA · monospacedDigit' }, { t: 'long-press → deep link' }]} />
      <Note n="2" {...noteL(28, 300)} ax={A(120, 250)[0]} ay={A(120, 250)[1]} title="Route overlay"
        lines={[{ t: 'MKPolyline · mrtGold', gold: true }, { t: 'travelled vs. ahead split' }, { t: 'glow drop-shadow' }]} />
      <Note n="3" {...noteL(28, 450)} find={byText('Cybercab')} ax={A(205, 300)[0]} ay={A(205, 300)[1]} title="Vehicle marker"
        lines={[{ t: 'custom MKAnnotationView' }, { t: 'heading arrow + pulse ring' }, { t: '2pt white stroke' }]} />
      <Note n="4" {...noteL(28, 600)} ax={A(201, 70)[0]} ay={A(201, 70)[1]} title="Vehicle switcher"
        lines={[{ t: 'tap dots (not swipe)' }, { t: 'active pill 22pt gold', gold: true }]} />

      {/* Right-side notes */}
      <Note n="5" side="l" {...noteR(150)} find={byText('Driving')} ax={A(64, 626)[0]} ay={A(64, 626)[1]} title="Status + range"
        lines={[{ t: 'driving dot #30D158', gold: true }, { t: 'MiniBattery + range mi' }]} />
      <Note n="6" side="l" {...noteR(290)} find={byText("Duarte")} anchor="l" ax={A(150, 660)[0]} ay={A(150, 660)[1]} title="Destination hero"
        lines={[{ t: 'Section Title 28/600' }, { t: '“Arriving in N min”' }, { t: 'ETA clock · tabular' }]} />
      <Note n="7" side="l" {...noteR(440)} ax={A(201, 712)[0]} ay={A(201, 712)[1]} title="TripProgressBar"
        lines={[{ t: 'gold fill + glow orb', gold: true }, { t: 'origin / dest captions' }]} />
      <Note n="8" side="l" {...noteR(580)} ax={A(360, 506)[0]} ay={A(360, 506)[1]} title="Recenter FAB"
        lines={[{ t: '44pt glass button' }, { t: 'location.fill · gold' }]} />
      <Note n="9" side="l" {...noteR(720)} find={byText('Vehicle')} ax={A(201, 818)[0]} ay={A(201, 818)[1]} title="Floating tab bar"
        lines={[{ t: 'capsule · inset 14pt' }, { t: 'active tab gold', gold: true }]} />
    </Board>
  );
}

// Left/right label placement helpers (board coords)
function noteL(x, y) { return { tx: x, ty: y, w: 200 }; }
function noteR(y) { return { tx: 1120 - 30 - 210, ty: y, w: 210 }; }

// ── 2 · Live Map · Parked ────────────────────────────────────
function BoardParkedHome() {
  return (
    <Board w={1120} h={940}>
      <BoardCap kicker="Owner · idle state" title="Live Map · Parked"
        sub="Map-first floating peek card. Expanding the sheet reveals the full VehicleControls stack." />
      <ScreenHost x={PX} y={PY}><AHome driving={false} /></ScreenHost>
      <Note n="1" {...noteL(28, 250)} ax={A(201, 360)[0]} ay={A(201, 360)[1]} title="Last-parked pin"
        lines={[{ t: 'parked marker #3B82F6', gold: true }, { t: 'static (no pulse)' }]} />
      <Note n="2" side="l" {...noteR(560)} find={byText('Cybercab')} ax={A(70, 640)[0]} ay={A(70, 640)[1]} title="Vehicle + battery"
        lines={[{ t: 'name 18/600 + StatusBadge' }, { t: 'BatteryBar 6pt' }]} />
      <Note n="3" side="l" {...noteR(700)} find={byText('Embarcadero')} ax={A(70, 700)[0]} ay={A(70, 700)[1]} title="Location + duration"
        lines={[{ t: 'address · text' }, { t: '“1h 42m” tabular' }]} />
      <Note n="4" {...noteL(28, 470)} ax={A(201, 612)[0]} ay={A(201, 612)[1]} title="Detent grip"
        lines={[{ t: 'peek 210 ↔ half 58%' }, { t: '.presentationDetents' }]} />
    </Board>
  );
}

// ── 3 · Shared Viewer · Idle ─────────────────────────────────
function BoardSharedIdle() {
  return (
    <Board w={1120} h={1000}>
      <BoardCap kicker="Shared · request entry" title="Shared Viewer · Idle"
        sub="Guest home. One expanding sheet whose phase swaps content from greeting → search → review → pending → tracking." />
      <ScreenHost x={PX} y={PY}><AShared /></ScreenHost>
      <Note n="1" side="l" {...noteR(150)} find={byText('Good')} anchor="l" ax={A(70, 420)[0]} ay={A(70, 420)[1]} title="Greeting"
        lines={[{ t: 'time-of-day · 21/500' }, { t: 'name glow reveal', gold: true }]} />
      <Note n="2" side="l" {...noteR(290)} ax={A(201, 470)[0]} ay={A(201, 470)[1]} title="Search field"
        lines={[{ t: 'animated border trace', gold: true }, { t: 'rotating placeholder' }]} />
      <Note n="3" side="l" {...noteR(430)} ax={A(120, 540)[0]} ay={A(120, 540)[1]} title="Saved places"
        lines={[{ t: 'Home / Work quick pick' }, { t: 'one tap → review' }]} />
      <Note n="4" side="l" {...noteR(570)} ax={A(120, 640)[0]} ay={A(120, 640)[1]} title="Map blend"
        lines={[{ t: 'map fades into page' }, { t: 'one continuous surface' }]} />
      <Note n="5" {...noteL(28, 250)} ax={A(201, 200)[0]} ay={A(201, 200)[1]} title="Live map base"
        lines={[{ t: 'rider sees the fleet' }, { t: 'MKMapView' }]} />
      <Note n="6" {...noteL(28, 520)} find={byText('Live Map')} ax={A(201, 815)[0]} ay={A(201, 815)[1]} title="Shared tab bar"
        lines={[{ t: 'Live Map · History · Settings' }, { t: 'hidden while booking' }]} />
    </Board>
  );
}

// ── 4 · Tracking ─────────────────────────────────────────────
function BoardTracking() {
  return (
    <Board w={1120} h={1000}>
      <BoardCap kicker="Shared · live ride" title="Tracking"
        sub="Two-leg live ride: the car drives to pickup, then to the destination. Plate is the spotting hero." />
      <ScreenHost x={PX} y={PY}><ATracking /></ScreenHost>
      <Note n="1" {...noteL(28, 220)} ax={A(120, 300)[0]} ay={A(120, 300)[1]} title="Live route + car"
        lines={[{ t: 'progress-driven car dot', gold: true }, { t: 'whole route fitted' }]} />
      <Note n="2" side="l" {...noteR(180)} ax={A(80, 470)[0]} ay={A(80, 470)[1]} title="Status line"
        lines={[{ t: 'PulseDot + stage word' }, { t: 'heading your way / heading to' }]} />
      <Note n="3" side="l" {...noteR(330)} ax={A(80, 560)[0]} ay={A(80, 560)[1]} title="Itinerary"
        lines={[{ t: 'pickup → drop-off rail' }, { t: 'arrival clocks · tabular' }]} />
      <Note n="4" side="l" {...noteR(500)} find={byText('RBO-2046')} ax={A(330, 700)[0]} ay={A(330, 700)[1]} title="License plate"
        lines={[{ t: 'Uber-prominent chip', gold: true }, { t: 'light plate on dark' }]} />
      <Note n="5" {...noteL(28, 420)} ax={A(201, 612)[0]} ay={A(201, 612)[1]} title="Arrival header"
        lines={[{ t: 'badge-less, clean rows' }, { t: 'shimmering gold “Arriving”', gold: true }, { t: 'ETA pair + belongings note' }]} />
    </Board>
  );
}

// —— 4b · Booking · Sending ————————————————————————————
function BoardBooking() {
  return (
    <Board w={1120} h={1040}>
      <BoardCap kicker="Shared · request confirm" title="Booking · Sending"
        sub="The review sheet committed: a compact left-aligned title, the full itinerary, the shared vehicle as a ‘Your ride’ + plate card, and a CTA whose gold fill slides across the 10-second send window before ‘Request sent’." />
      <ScreenHost x={PX} y={PY}><ABooking /></ScreenHost>
      <Note n="1" {...noteL(28, 300)} find={byText('Booking ride')} ax={A(201, 360)[0]} ay={A(201, 360)[1]} title="Title"
        lines={[{ t: '“Booking ride with …”' }, { t: 'owner name in gold', gold: true }]} />
      <Note n="2" side="l" {...noteR(200)} find={byText('PICKUP')} anchor="l" ax={A(80, 470)[0]} ay={A(80, 470)[1]} title="Itinerary"
        lines={[{ t: 'pickup → drop-off rail' }, { t: 'clocks + mi/min · tabular' }]} />
      <Note n="3" side="l" {...noteR(360)} find={byText('Your ride')} ax={A(80, 600)[0]} ay={A(80, 600)[1]} title="Your ride"
        lines={[{ t: 'color + model name' }, { t: 'plate chip · monospaced', gold: true }]} />
      <Note n="5" side="l" {...noteR(540)} find={byText('Sending request')} ax={A(201, 800)[0]} ay={A(201, 800)[1]} title="Send CTA"
        lines={[{ t: 'gold fill slides L→R / 10s', gold: true }, { t: 'border trace + countdown' }, { t: 'tap = send now' }]} />
      <Note n="6" side="l" {...noteR(720)} find={byText('Cancel request')} ax={A(201, 850)[0]} ay={A(201, 850)[1]} title="Cancel"
        lines={[{ t: 'quiet destructive link' }, { t: 'drops the pending ride' }]} />
    </Board>
  );
}

// ── 7 · Ride Summary (trip complete) ─────────────────────────
function BoardSummary() {
  return (
    <Board w={1120} h={1040}>
      <BoardCap kicker="Shared · trip complete" title="Ride Summary"
        sub="Full-screen takeover the moment the ride ends: a shimmering-gold greeting, the route on a real map snippet, a hairline stat strip, the vehicle, and a tip row where every option is a gentle joke — there is no driver to tip." />
      <ScreenHost x={PX} y={PY}><ASummary /></ScreenHost>
      <Note n="1" {...noteL(28, 200)} find={byText('Have a wonderful')} ax={A(70, 200)[0]} ay={A(70, 200)[1]} title="Greeting"
        lines={[{ t: 'time-of-day + name' }, { t: 'shimmering gold text', gold: true }]} />
      <Note n="2" {...noteL(28, 380)} find={byText('You arrived at')} ax={A(120, 470)[0]} ay={A(120, 470)[1]} title="Journey map"
        lines={[{ t: 'real MapBackground + route', gold: true }, { t: 'destination rests on gradient' }]} />
      <Note n="3" side="l" {...noteR(220)} find={byText('FSD miles')} ax={A(200, 660)[0]} ay={A(200, 660)[1]} title="Stat strip"
        lines={[{ t: 'Trip · FSD miles · Autonomous' }, { t: 'hairline dividers, no boxes' }, { t: 'FSD value gold', gold: true }]} />
      <Note n="4" side="l" {...noteR(400)} find={byText('You rode in')} ax={A(200, 740)[0]} ay={A(200, 740)[1]} title="Vehicle"
        lines={[{ t: 'quiet line + hairline' }, { t: 'plate chip', gold: true }]} />
      <Note n="5" side="l" {...noteR(560)} find={byText('Tip your driver')} ax={A(200, 800)[0]} ay={A(200, 800)[1]} title="Tip (the joke)"
        lines={[{ t: '$3 / $5 / $8 / Custom' }, { t: 'tap → bottom-sheet deadpan' }, { t: '“Haha, no need!”', gold: true }]} />
      <Note n="6" {...noteL(28, 560)} find={byText('See you soon')} ax={A(201, 850)[0]} ay={A(201, 850)[1]} title="Farewell CTA"
        lines={[{ t: 'outline-draw gold trace', gold: true }, { t: 'returns to the map' }]} />
    </Board>
  );
}

// ── 5 · Drives (list patterns) ───────────────────────────────
function BoardDrives() {
  return (
    <Board w={1120} h={940}>
      <BoardCap kicker="Owner · list patterns" title="Drives"
        sub="History + Upcoming segments. Establishes the elevated gold-tinted row + grouped-section vocabulary reused across the app." />
      <ScreenHost x={PX} y={PY}><ADrives /></ScreenHost>
      <Note n="1" side="l" {...noteR(150)} find={byText('Drives')} anchor="l" ax={A(60, 120)[0]} ay={A(60, 120)[1]} title="Screen header"
        lines={[{ t: 'Title 28/600 + subtitle' }, { t: '54pt safe-area top' }]} />
      <Note n="2" side="l" {...noteR(290)} find={byText('History')} ax={A(201, 210)[0]} ay={A(201, 210)[1]} title="Segmented control"
        lines={[{ t: 'History ↔ Upcoming' }, { t: 'count badge in label' }]} />
      <Note n="3" side="l" {...noteR(430)} ax={A(201, 300)[0]} ay={A(201, 300)[1]} title="Live trip banner"
        lines={[{ t: 'green wash + PulseDot', gold: true }, { t: 'tap → back to map' }]} />
      <Note n="4" side="l" {...noteR(580)} ax={A(201, 470)[0]} ay={A(201, 470)[1]} title="DriveRow"
        lines={[{ t: 'gold wash card · 16pt' }, { t: 'route → · FSD %' }]} />
      <Note n="5" {...noteL(28, 380)} ax={A(60, 380)[0]} ay={A(60, 380)[1]} title="Group label"
        lines={[{ t: 'Today / Yesterday' }, { t: 'Label 10/500 caps' }]} />
    </Board>
  );
}

// ── 6 · Incoming Request (owner modal) ───────────────────────
function BoardIncoming() {
  return (
    <Board w={1120} h={980}>
      <BoardCap kicker="Owner · modal overlay" title="Incoming Request"
        sub="Owner-side ride request. Accept routes the car and texts the rider a tracking link; decline dismisses." />
      <ScreenHost x={PX} y={PY}><AIncoming /></ScreenHost>
      <Note n="1" {...noteL(28, 250)} ax={A(201, 360)[0]} ay={A(201, 360)[1]} title="Scrim + blur"
        lines={[{ t: 'rgba(0,0,0,.5) + blur 8px' }, { t: 'dims the map behind' }]} />
      <Note n="2" side="l" {...noteR(180)} find={byText('Sam')} anchor="l" ax={A(80, 470)[0]} ay={A(80, 470)[1]} title="Requester"
        lines={[{ t: 'avatar + name' }, { t: '“wants a ride”' }]} />
      <Note n="3" side="l" {...noteR(330)} ax={A(201, 560)[0]} ay={A(201, 560)[1]} title="Route preview"
        lines={[{ t: 'map snippet + gradient' }, { t: 'distance · time · battery' }]} />
      <Note n="4" side="l" {...noteR(500)} find={byText('Decline')} ax={A(130, 770)[0]} ay={A(130, 770)[1]} title="Decline / Accept"
        lines={[{ t: 'destructive + outline-draw' }, { t: 'sending → sent states', gold: true }]} />
      <Note n="5" {...noteL(28, 470)} ax={A(201, 612)[0]} ay={A(201, 612)[1]} title="Modal sheet"
        lines={[{ t: 'radius 28–32pt' }, { t: 'slides from bottom' }]} />
    </Board>
  );
}

// ── 0 · Sign In (onboarding) ─────────────────────────────────
function BoardSignIn() {
  return (
    <Board w={1120} h={940}>
      <BoardCap kicker="Onboarding · owner + shared" title="Sign In"
        sub="Single entry for both flows. Brand mark over a calm gold wash, a live glimpse line that builds from gold particles, and a swipe-up to the Apple-only sheet." />
      <ScreenHost x={PX} y={PY}><SignInScreen onSignIn={() => {}} /></ScreenHost>

      <Note n="1" {...noteL(28, 200)} ax={A(201, 360)[0]} ay={A(201, 360)[1]} title="Brand mark"
        lines={[{ t: 'flat facet arrow tile', gold: true }, { t: 'no glow · 62pt' }]} />
      <Note n="2" {...noteL(28, 360)} ax={A(201, 452)[0]} ay={A(201, 452)[1]} title="Wordmark"
        lines={[{ t: 'MYROBOTAXI · Roboto 500' }, { t: 'all-caps · +0.04em' }]} />
      <Note n="3" {...noteL(28, 520)} ax={A(201, 510)[0]} ay={A(201, 510)[1]} title="Live glimpse"
        lines={[{ t: 'canvas particle line', gold: true }, { t: 'builds L→R · crisp hold' }, { t: 'swaps with no blank' }]} />
      <Note n="4" side="l" {...noteR(220)} find={byText('Swipe up to sign in')} anchor="l" ax={A(201, 800)[0]} ay={A(201, 800)[1]} title="Swipe affordance"
        lines={[{ t: 'pulsing gold line', gold: true }, { t: 'floating chevrons' }, { t: 'drag ↑ or tap' }]} />
      <Note n="5" side="l" {...noteR(420)} ax={A(201, 612)[0]} ay={A(201, 612)[1]} title="Apple sheet"
        lines={[{ t: 'swipe → bottom sheet' }, { t: 'Sign in with Apple only' }, { t: 'white ASAuthorization btn' }]} />
      <Note n="6" side="l" {...noteR(600)} ax={A(201, 470)[0]} ay={A(201, 470)[1]} title="Hand-off"
        lines={[{ t: 'gold bloom + zoom out', gold: true }, { t: 'eases into the app' }]} />
    </Board>
  );
}

Object.assign(window, { BoardSignIn, BoardDrivingHome, BoardParkedHome, BoardSharedIdle, BoardTracking, BoardBooking, BoardSummary, BoardDrives, BoardIncoming });

// ── 10 · Empty State (onboarding choice) ─────────────────────
function BoardEmpty() {
  return (
    <Board w={1120} h={940}>
      <BoardCap kicker="Onboarding · first run" title="Empty State"
        sub="Two self-describing choice cards over the brand gold wash — pick a path. The primary is emphasized by fill + border, not by an animated trace." />
      <ScreenHost x={PX} y={PY}><EmptyScreen onAdd={() => {}} onInvite={() => {}} /></ScreenHost>
      <Note n="1" {...noteL(28, 220)} find={byText('Welcome to')} ax={A(201, 420)[0]} ay={A(201, 420)[1]} title="Brand mark + welcome"
        lines={[{ t: 'HexLogo 58pt · glow', gold: true }, { t: 'gold wash from top' }]} />
      <Note n="2" side="l" {...noteR(300)} find={byText('Add your Tesla')} anchor="l" ax={A(201, 540)[0]} ay={A(201, 540)[1]} title="Primary path"
        lines={[{ t: 'gold fill + solid gold border', gold: true }, { t: 'icon + title + descriptor' }, { t: '→ AddTeslaFlow' }]} />
      <Note n="3" side="l" {...noteR(480)} find={byText('Join with')} anchor="l" ax={A(201, 640)[0]} ay={A(201, 640)[1]} title="Secondary path"
        lines={[{ t: 'quiet matching card' }, { t: 'same shape / radius' }, { t: '→ InviteCodeFlow' }]} />
    </Board>
  );
}

// ── 11 · Add Your Tesla (owner pairing) ──────────────────────
function BoardAddTesla() {
  return (
    <Board w={1120} h={940}>
      <BoardCap kicker="Onboarding · owner" title="Add Your Tesla"
        sub="4-step tracked pairing. Intro shown; flow runs Sign in → Linked → Virtual key → Paired via an in-app OAuth browser, a virtual-key card, and a celebratory paired reveal." />
      <ScreenHost x={PX} y={PY}><AddTeslaFlow onComplete={() => {}} onCancel={() => {}} /></ScreenHost>
      <Note n="1" {...noteL(28, 200)} find={byText('Sign in')} ax={A(60, 92)[0]} ay={A(60, 92)[1]} title="PairStepper"
        lines={[{ t: 'Sign in · Linked · Key · Paired' }, { t: 'gold-deep done/active', gold: true }, { t: 'sits below Cancel' }]} />
      <Note n="2" {...noteL(28, 400)} ax={A(201, 300)[0]} ay={A(201, 300)[1]} title="Brand mark + rings"
        lines={[{ t: 'expanding mrtRingPulse', gold: true }, { t: 'HexLogo 76 · glow' }]} />
      <Note n="3" side="l" {...noteR(300)} find={byText('Sign in with Tesla')} anchor="l" ax={A(201, 720)[0]} ay={A(201, 720)[1]} title="Sign in CTA"
        lines={[{ t: 'outline-static (no trace)' }, { t: '→ in-app OAuth browser' }, { t: 'ASWebAuthenticationSession' }]} />
      <Note n="4" side="l" {...noteR(480)} ax={A(201, 640)[0]} ay={A(201, 640)[1]} title="Later phases"
        lines={[{ t: 'consent → key card (shimmer)', gold: true }, { t: 'Tesla-app handoff → waiting' }, { t: 'paired: gold bloom reveal' }]} />
      <Note n="5" side="l" {...noteR(640)} ax={A(201, 795)[0]} ay={A(201, 795)[1]} title="Trust note"
        lines={[{ t: 'lock.fill · secured by Tesla' }, { t: 'we never see the password' }]} />
    </Board>
  );
}

// ── 12 · Enter Invite Code (rider join) ──────────────────────
function BoardInvite() {
  return (
    <Board w={1120} h={940}>
      <BoardCap kicker="Onboarding · rider" title="Enter Invite Code"
        sub="6-cell code entry backed by a hidden field. Verifies, then a celebratory ‘You’re in’ card names whose Tesla you joined." />
      <ScreenHost x={PX} y={PY}><InviteCodeFlow onComplete={() => {}} onCancel={() => {}} /></ScreenHost>
      <Note n="1" {...noteL(28, 220)} find={byText('Enter invite')} ax={A(201, 320)[0]} ay={A(201, 320)[1]} title="Brand mark + title"
        lines={[{ t: 'HexLogo 60 · gold wash', gold: true }]} />
      <Note n="2" side="l" {...noteR(280)} ax={A(201, 470)[0]} ay={A(201, 470)[1]} title="Code cells"
        lines={[{ t: '6 cells · hidden input' }, { t: 'active ring + caret', gold: true }, { t: 'shake on error' }]} />
      <Note n="3" side="l" {...noteR(460)} find={byText('Use sample')} anchor="l" ax={A(201, 800)[0]} ay={A(201, 800)[1]} title="Sample shortcut"
        lines={[{ t: 'auto-submits at 6 chars' }, { t: '→ verifying → joined' }, { t: 'from Settings: returns (Done)' }]} />
    </Board>
  );
}

// ── 13 · Tutorial (story cards) ──────────────────────────────
function BoardTutorial() {
  return (
    <Board w={1120} h={940}>
      <BoardCap kicker="Onboarding · both flows" title="Tutorial · Story cards"
        sub="Paged story-card deck (Things/Linear style). Each card: a hero vignette built from real app primitives, big title + body, page dots, an outline-static CTA. Owner + Rider decks share the engine." />
      <ScreenHost x={PX} y={PY}><OwnerTutorial onDone={() => {}} /></ScreenHost>
      <Note n="1" {...noteL(28, 200)} find={byText('GETTING')} ax={A(90, 96)[0]} ay={A(90, 96)[1]} title="Kicker + Skip"
        lines={[{ t: 'brand mark + label', gold: true }, { t: 'Skip pinned top-right' }]} />
      <Note n="2" {...noteL(28, 420)} ax={A(201, 380)[0]} ay={A(201, 380)[1]} title="Hero vignette"
        lines={[{ t: 'real app primitives', gold: true }, { t: 'mrtVigFloat bob · mrtStoryIn slide' }]} />
      <Note n="3" side="l" {...noteR(260)} find={byText('Your car')} anchor="l" ax={A(70, 700)[0]} ay={A(70, 700)[1]} title="Title + body"
        lines={[{ t: 'Screen Title 27/600' }, { t: 'body 15 · text.sec' }]} />
      <Note n="4" side="l" {...noteR(460)} ax={A(201, 795)[0]} ay={A(201, 795)[1]} title="Dots + CTA"
        lines={[{ t: 'active dot 22×7 gold', gold: true }, { t: 'Continue → last fires onDone' }, { t: 'swipe or tap' }]} />
    </Board>
  );
}

Object.assign(window, { BoardEmpty, BoardAddTesla, BoardInvite, BoardTutorial });
