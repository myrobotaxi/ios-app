// MyRoboTaxi · iOS Design System — Screen gallery + handoff.
// Renders every real screen (owner + shared + overlays) in a mini phone.

const { useState: scS } = React;

const DOC_UPCOMING = [
  { id: 'ou1', rider: 'Mira', dest: { label: 'SFO · Terminal 2', sub: 'San Francisco International', miles: 18.4, mins: 32 }, schedule: { day: 'Tomorrow', time: '6:40 AM' }, vehicle: 'Cybercab' },
];

// ── Screen card: mini phone + meta block ─────────────────────
function ScreenCard({ title, tag, spec, interaction, di, scale = 0.46, children, span }) {
  return (
    <div style={{ gridColumn: span ? `span ${span}` : undefined }}>
      <MiniPhone scale={scale} di={di} label={
        <div style={{ marginTop: 4 }}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, justifyContent: 'center', flexWrap: 'wrap' }}>
            <span style={{ fontSize: 14, fontWeight: 600, color: T.text }}>{title}</span>
            {tag && <span style={{ fontFamily: DS_MONO, fontSize: 10.5, color: T.gold }}>{tag}</span>}
          </div>
          {spec && <div style={{ fontSize: 11.5, color: T.textSec, lineHeight: 1.5, marginTop: 6, maxWidth: 230 }}>{spec}</div>}
          {interaction && <div style={{ fontSize: 11, color: T.textMuted, lineHeight: 1.45, marginTop: 6, maxWidth: 230 }}>{interaction}</div>}
        </div>
      }>{children}</MiniPhone>
    </div>
  );
}

// ── Stateful wrappers (documentation defaults) ───────────────
function W_Home({ driving }) {
  const [vIdx, setVIdx] = scS(0);
  const [sheet, setSheet] = scS('peek');
  const [nav, setNav] = scS('home');
  return <HomeScreen vehicleIdx={vIdx} setVehicleIdx={setVIdx} sheet={sheet} setSheet={setSheet}
    driving={driving} progress={0.46} battery={68} speed={64} parkedStyle="floating"
    nav={nav} setNav={setNav} mapHeight={874} />;
}
function W_HomeControls() {
  const [vIdx, setVIdx] = scS(0);
  const [sheet, setSheet] = scS('half');
  const [nav, setNav] = scS('home');
  return <HomeScreen vehicleIdx={vIdx} setVehicleIdx={setVIdx} sheet={sheet} setSheet={setSheet}
    driving={false} progress={0.46} battery={68} speed={0} parkedStyle="floating"
    nav={nav} setNav={setNav} mapHeight={874} />;
}
function W_Drives() {
  const [nav, setNav] = scS('drives');
  return <DrivesScreen nav={nav} setNav={setNav} onOpenDrive={() => {}} driving upcoming={DOC_UPCOMING} onCancelUpcoming={() => {}} />;
}
function W_Invites() { const [n, sN] = scS('invites'); return <InvitesScreen nav={n} setNav={sN} />; }
function W_Settings() { const [n, sN] = scS('settings'); return <SettingsScreen nav={n} setNav={sN} onAddTesla={() => {}} onSignOut={() => {}} />; }
function W_AddTesla() { return <AddTeslaFlow onComplete={() => {}} onCancel={() => {}} />; }
function W_OwnerTutorial() { return <OwnerTutorial onDone={() => {}} />; }
function W_RiderTutorial() { return <RiderTutorial onDone={() => {}} />; }
function W_InviteCode() { return <InviteCodeFlow onComplete={() => {}} onCancel={() => {}} />; }
function W_DriveSummary() { return <DriveSummaryScreen driveId="d7" onBack={() => {}} />; }

function W_Shared({ state = 'idle', phase, dest: destProp, progress = 0.5 }) {
  const [nav, setNav] = scS('shared');
  const [rs, setRs] = scS(state);
  const defaultDest = { id: 'pescadero', label: "Duarte's Tavern", sub: '202 Stage Rd · Pescadero', miles: 41.2, mins: 87 };
  const [dest, setDest] = scS(destProp !== undefined ? destProp : (state === 'idle' && !phase ? null : defaultDest));
  return <SharedViewerScreen progress={progress} battery={68} speed={58} driving={state === 'accepted'}
    riderName="Sam" requestState={rs} setRequestState={setRs}
    requestDest={dest} setRequestDest={setDest}
    requestPassenger={null} setRequestPassenger={() => {}}
    nav="shared" setNav={setNav} docFreeze initialPhase={phase} />;
}
function W_RideHistory() { const [n, sN] = scS('rideHistory'); return <RideHistoryScreen nav={n} setNav={sN} riderName="Sam" />; }
function W_SharedSettings() { const [n, sN] = scS('sharedSettings'); return <SharedSettingsScreen nav={n} setNav={sN} riderName="Sam" />; }

function W_Incoming() {
  const [vIdx, setVIdx] = scS(0);
  const [sheet, setSheet] = scS('peek');
  const dest = { id: 'pescadero', label: "Duarte's Tavern", sub: '202 Stage Rd · Pescadero', miles: 41.2, mins: 87 };
  return (
    <>
      <HomeScreen vehicleIdx={vIdx} setVehicleIdx={setVIdx} sheet={sheet} setSheet={setSheet}
        driving={false} progress={0.46} battery={68} speed={0} parkedStyle="floating"
        nav="home" setNav={() => {}} mapHeight={874} />
      <IncomingRequestSheet visible requesterName="Sam" dest={dest} vehicleName="Cybercab"
        battery={68} kind="now" onAccept={() => {}} onReject={() => {}} />
    </>
  );
}
function W_IncomingScheduled() {
  const [vIdx, setVIdx] = scS(0);
  const [sheet, setSheet] = scS('peek');
  const dest = { id: 'sfo', label: 'SFO · Terminal 2', sub: 'San Francisco International', miles: 18.4, mins: 32 };
  return (
    <>
      <HomeScreen vehicleIdx={vIdx} setVehicleIdx={setVIdx} sheet={sheet} setSheet={setSheet}
        driving={false} progress={0.46} battery={68} speed={0} parkedStyle="floating"
        nav="home" setNav={() => {}} mapHeight={874} />
      <IncomingRequestSheet visible requesterName="Sam" dest={dest} vehicleName="Cybercab"
        battery={68} kind="scheduled" schedule={{ day: 'Fri', time: '5:30 PM' }} onAccept={() => {}} onReject={() => {}} />
    </>
  );
}

// ── Screens section ──────────────────────────────────────────
function ScreensSection() {
  return (
    <Section id="screens" num="09" title="Screens"
      intro="Every screen, rendered live. Two top-level flows share the kit: Owner (full vehicle control) and Shared (guest who can request rides and watch the map). Open the anatomy canvas for labeled, exploded breakdowns of each.">

      <Sub title="Onboarding" hint="First run → paired / joined">
        <Grid min={210} gap={28}>
          <ScreenCard title="Sign In" tag="SignInScreen"
            spec="Brand mark + live particle glimpse line; swipe-up reveals an Apple-only sheet. Shared by owner & shared flows."
            interaction="Swipe up (or tap) → Sign in with Apple; gold bloom hands off into the app.">
            <SignInScreen onSignIn={() => {}} />
          </ScreenCard>
          <ScreenCard title="Empty State" tag="EmptyScreen"
            spec="First run — two self-describing choice cards: 'Add your Tesla' (emphasized, gold fill + solid gold border) and 'Join with an invite code' (quiet matching card)."
            interaction="Tap a card → pairing flow or invite-code flow.">
            <EmptyScreen onAdd={() => {}} onInvite={() => {}} />
          </ScreenCard>
          <ScreenCard title="Add Your Tesla" tag="AddTeslaFlow"
            spec="4-step tracked pairing (Sign in → Linked → Virtual key → Paired) via PairStepper. In-app browser (Safari-VC style) hosts an ORIGINAL Tesla OAuth mock + scopes consent, auto-dismisses on grant. Then a shimmering virtual key card + Tesla-app handoff, ending in a celebratory gold-bloom 'You're paired' vehicle reveal."
            interaction="Sign in with Tesla → Allow access → Open Tesla app → waiting → paired → owner tutorial.">
            <W_AddTesla />
          </ScreenCard>
          <ScreenCard title="Owner Tutorial" tag="OwnerTutorial / StoryDeck"
            spec="5 paged story cards (Things/Linear style): full-bleed swipeable slides, a hero vignette built from REAL app primitives, big title + body, page dots, gold outline CTA. Covers live map, drive history, sharing, ride requests, climate/controls."
            interaction="Swipe or tap Continue; dots jump; Skip exits. Last card → Live Map.">
            <W_OwnerTutorial />
          </ScreenCard>
          <ScreenCard title="Enter Invite Code" tag="InviteCodeFlow"
            spec="6-cell code entry with a hidden input + animated caret; shake on error; 'Use sample code' shortcut. Verifying spinner → 'You're in' success card naming whose Tesla you joined."
            interaction="Type 6 chars (auto-submits) → verifying → joined → rider tutorial. From Settings it returns instead (CTA 'Done').">
            <W_InviteCode />
          </ScreenCard>
          <ScreenCard title="Rider Tutorial" tag="RiderTutorial / StoryDeck"
            spec="5 paged story cards for guests: requesting a ride, live tracking/ETA, ride history, cars shared with you, and safety boundaries (what you can & can't do)."
            interaction="Swipe or Continue; Skip exits. Last card → Shared Live Map.">
            <W_RiderTutorial />
          </ScreenCard>
        </Grid>
      </Sub>

      <Sub title="Owner flow" hint="Vehicle · Drives · Share · Settings">
        <Grid min={210} gap={28}>
          <ScreenCard title="Live Map · Driving" tag="HomeScreen"
            spec="Map + route + vehicle marker. Sheet hero = destination + ETA."
            interaction="Sheet drags peek ↔ half; half reveals VehicleControls.">
            <W_Home driving />
          </ScreenCard>
          <ScreenCard title="Live Map · Parked" tag="parkedStyle"
            spec="Floating card peek — location, battery, duration."
            interaction="Three peek styles: floating · pill · sheet.">
            <W_Home driving={false} />
          </ScreenCard>
          <ScreenCard title="Vehicle Controls" tag="sheet: half"
            spec="Half-detent reveals the control stack — lock, climate, media, charge, plus quick-control tiles."
            interaction="Drag the sheet to half; tiles toggle live vehicle state.">
            <W_HomeControls />
          </ScreenCard>
          <ScreenCard title="Drives" tag="DrivesScreen"
            spec="History + Upcoming segments. Grouped, sortable rows."
            interaction="Tap a row → Drive Summary. Cancel reserved rides.">
            <W_Drives />
          </ScreenCard>
          <ScreenCard title="Drive Summary" tag="DriveSummaryScreen"
            spec="Hero map, stat grid, speed sparkline, FSD share."
            interaction="Share via UIActivityViewController.">
            <W_DriveSummary />
          </ScreenCard>
          <ScreenCard title="Share" tag="InvitesScreen"
            spec="Invite viewers by email; manage viewers + pending. Send opens a config sheet (which Tesla + cumulative access), then sending → sent. Revoke / cancel / resend each open a confirmation dialog + success toast."
            interaction="Send invite → access sheet; Revoke/Cancel → confirm dialog; Resend → confirm + toast.">
            <W_Invites />
          </ScreenCard>
          <ScreenCard title="Settings" tag="SettingsScreen"
            spec="Profile; Tesla Account lists ALL linked vehicles (Primary badge, tap → detail sheet to set-primary / unlink); 'Shared with' viewer list with revoke; notification toggles; sign out."
            interaction="Add another Tesla → pairing; tap vehicle → detail sheet; Revoke/Unlink/Sign out → confirm dialogs.">
            <W_Settings />
          </ScreenCard>
        </Grid>
      </Sub>

      <Sub title="Shared-viewer flow" hint="Guest access">
        <Grid min={210} gap={28}>
          <ScreenCard title="Live Map · Idle" tag="SharedViewerScreen"
            spec="Greeting, search, Home/Work — on a map that dissolves seamlessly into the page (no floating card seam)."
            interaction="Expanding sheet drives the whole request flow by phase.">
            <W_Shared state="idle" />
          </ScreenCard>
          <ScreenCard title="Search" tag="phase: search"
            spec="Destination search with a rotating placeholder, Me/for-someone toggle, saved places, and a drop-a-pin option."
            interaction="Type or pick a place → Review. Drag down to dismiss.">
            <W_Shared phase="search" />
          </ScreenCard>
          <ScreenCard title="Pin drop" tag="phase: pinDrop"
            spec="Choose pickup on the map — drag the pin, reverse-geocoded address updates live."
            interaction="Confirm pickup here → back to Search with the spot set.">
            <W_Shared phase="pinDrop" />
          </ScreenCard>
          <ScreenCard title="Review · Request" tag="phase: review"
            spec="Confirm trip + choose whose shared Tesla to ask. The request CTA is the outline-draw trace: ‘Request from Alex’."
            interaction="Tap Request → Booking/Sending. Owner must accept.">
            <W_Shared phase="review" />
          </ScreenCard>
          <ScreenCard title="Booking · Sending" tag="phase: pending"
            spec="Confirms the request: itinerary (pickup → drop-off), the shared vehicle, and a CTA whose gold fill slides over the 10s send window."
            interaction="Tap the CTA to send instantly → ‘Request sent’ → minimizes to the map with a live pending banner.">
            <W_Shared state="pending" />
          </ScreenCard>
          <ScreenCard title="Declined" tag="requestState: rejected"
            spec="Owner can’t take the ride. A light notice over the search screen — no full-screen dead-end."
            interaction="Dismiss to idle, or Rebook to retry the request.">
            <W_Shared state="rejected" />
          </ScreenCard>
          <ScreenCard title="Tracking" tag="phase: tracking"
            spec="Live two-leg ride — pickup then drop-off, plate hero; map blends into the page, no drag handle. Arrival collapses to a clean, badge-less header: a shimmering gold ‘Arriving’, ETA pair, and a hairline belongings note."
            interaction="Drag down to minimize to the map.">
            <W_Shared state="accepted" />
          </ScreenCard>
          <ScreenCard title="Ride Summary" tag="trip complete"
            spec="Full-screen takeover the moment the ride ends. Shimmering-gold greeting (‘Have a wonderful evening, Sam’), the route on a real map snippet with the destination resting on it, a hairline stat strip (Trip · FSD miles · Autonomous), the vehicle + plate, and a tip row where every option is a joke — no driver to tip."
            interaction="Tap a tip → an elegant bottom sheet deadpans back (‘Haha, no need!’). ‘See you soon’ returns to the map.">
            <W_Shared state="accepted" progress={1} />
          </ScreenCard>
          <ScreenCard title="Ride History" tag="RideHistoryScreen"
            spec="Completed + Scheduled rides; tap to reschedule / cancel.">
            <W_RideHistory />
          </ScreenCard>
          <ScreenCard title="Settings" tag="SharedSettingsScreen"
            spec="Guest profile, shared-with-me vehicles, notifications.">
            <W_SharedSettings />
          </ScreenCard>
        </Grid>
      </Sub>

      <Sub title="Cross-flow overlays">
        <Grid min={210} gap={28}>
          <ScreenCard title="Incoming Request" tag="IncomingRequestSheet"
            spec="Owner-side modal — accept routes the car, decline dismisses."
            interaction="Accept → sending → sent confirmation, then dispatch.">
            <W_Incoming />
          </ScreenCard>
          <ScreenCard title="Incoming · Scheduled" tag="kind: scheduled"
            spec="A reserved-time request — shows the schedule chip; accepting reserves the car for later instead of dispatching now."
            interaction="Accept → added to Upcoming; decline dismisses.">
            <W_IncomingScheduled />
          </ScreenCard>
        </Grid>
        <div style={{ marginTop: 22, padding: '16px 18px', background: T.surface, border: `0.5px solid ${T.border}`, borderRadius: 14, display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
          <SFIcon name="square.and.arrow.up" size={18} color={T.gold} />
          <span style={{ fontSize: 13, color: T.textSec, lineHeight: 1.5, flex: 1, minWidth: 200 }}>
            Home-screen widgets, Lock-Screen widgets, StandBy, the Dynamic Island long-press menu and all Live Activity states live on the dedicated surfaces canvas.
          </span>
          <DocLink href="surfaces.html">Open surfaces →</DocLink>
        </div>
      </Sub>
    </Section>
  );
}

// ── Handoff: deviations + open questions ─────────────────────
function HandoffSection() {
  return (
    <Section id="handoff" num="10" title="Handoff notes"
      intro="Where the native build intentionally diverges from this web prototype, and the decisions still open. Read these before wiring ActivityKit or MapKit.">
      <Grid min={320}>
        <Card>
          <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase', color: T.gold, marginBottom: 8 }}>Web → iOS deviations</div>
          {DEVIATIONS.map(([t, b], i) => (
            <div key={i} style={{ padding: '13px 0', borderTop: i ? `0.5px solid ${T.border}` : 'none' }}>
              <div style={{ fontSize: 12.5, color: T.gold, fontWeight: 500, marginBottom: 5, lineHeight: 1.45 }}>{t}</div>
              <div style={{ fontSize: 12.5, color: T.textSec, lineHeight: 1.55 }}>{b}</div>
            </div>
          ))}
        </Card>
        <Card>
          <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase', color: T.gold, marginBottom: 8 }}>Open questions</div>
          {OPEN_QUESTIONS.map(([t, b], i) => (
            <div key={i} style={{ padding: '13px 0', borderTop: i ? `0.5px solid ${T.border}` : 'none' }}>
              <div style={{ fontSize: 13, color: T.text, fontWeight: 600, marginBottom: 4 }}>{t}</div>
              <div style={{ fontSize: 12.5, color: T.textSec, lineHeight: 1.55 }}>{b}</div>
            </div>
          ))}
        </Card>
      </Grid>
      <div style={{ marginTop: 30, padding: '22px 24px', borderRadius: 16, background: 'linear-gradient(135deg, rgba(201,168,76,0.10), rgba(201,168,76,0.02))', border: `0.5px solid ${T.gold}33`, display: 'flex', alignItems: 'center', gap: 18, flexWrap: 'wrap' }}>
        <HexLogo size={36} />
        <div style={{ flex: 1, minWidth: 220 }}>
          <div style={{ fontSize: 15, fontWeight: 600, color: T.text, marginBottom: 3 }}>Ready to build</div>
          <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.5 }}>Pair this spec with the labeled anatomy canvas and the live prototype for full context.</div>
        </div>
        <div style={{ display: 'flex', gap: 10 }}>
          <DocLink href="Handoff for Claude Code.md" primary>Build handoff →</DocLink>
          <DocLink href="Anatomy.html">Anatomy</DocLink>
          <DocLink href="prototype.html">Prototype</DocLink>
        </div>
      </div>
    </Section>
  );
}

Object.assign(window, { ScreensSection, HandoffSection, ScreenCard });
