// MyRoboTaxi — onboarding tutorials. Paged "story cards" (Things / Linear style):
// full-bleed swipeable slides, a hero vignette built from REAL app primitives,
// a big title + body, page dots, and a gold CTA. One deck powers both the
// Owner and Rider walkthroughs.

const { useState: tS, useRef: tR, useEffect: tE } = React;

// ── Vignette shell — a floating "mini screen" the feature is shown inside ──
function MiniScreen({ children, w = 250, h = 250, pad = 0 }) {
  return (
    <div style={{ width: w, height: h, borderRadius: 28, position: 'relative', overflow: 'hidden', padding: pad,
      background: 'linear-gradient(160deg, rgba(34,34,40,0.9), rgba(16,16,20,0.92))',
      border: '0.5px solid rgba(255,255,255,0.10)',
      boxShadow: '0 30px 70px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.10)' }}>
      {children}
    </div>);
}

const tFloat = { animation: 'mrtVigFloat 4s ease-in-out infinite' };

// ── Owner vignettes ──────────────────────────────────────────
function VigLiveMap() {
  const route = (window.buildSampleRoute && window.buildSampleRoute()) || [];
  return (
    <MiniScreen w={252} h={252}>
      <MapBackground width={252} height={252} seed={42}/>
      <svg width="252" height="252" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
        <RouteLine path={route} progress={0.5} width={6}/>
      </svg>
      <div style={{ position: 'absolute', top: '46%', left: '52%', transform: 'translate(-50%,-50%)' }}>
        <VehicleMarker heading={48} size={22}/>
      </div>
      {/* status pill */}
      <div style={{ position: 'absolute', left: 12, right: 12, bottom: 12, height: 52, borderRadius: 16,
        background: 'rgba(20,20,24,0.66)', backdropFilter: 'blur(18px)', border: '0.5px solid rgba(255,255,255,0.12)',
        display: 'flex', alignItems: 'center', padding: '0 14px', gap: 10 }}>
        <PulseDot color={T.driving} size={7}/>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 12.5, fontWeight: 600, color: T.text }}>Cybercab · Driving</div>
          <div style={{ fontSize: 10.5, color: T.textSec, marginTop: 1 }}>64 mph · 68%</div>
        </div>
        <div style={{ fontFamily: T.fontNum, fontSize: 19, fontWeight: 500, color: T.gold }}>12<span style={{ fontSize: 10, marginLeft: 2 }}>min</span></div>
      </div>
    </MiniScreen>);
}

function VigDrives() {
  const rows = [
    { to: 'Embarcadero Center', sub: 'Today · 7:42 AM', mi: '14.6', mn: '29' },
    { to: 'Half Moon Bay', sub: 'Yest. · 9:02 AM', mi: '28.4', mn: '92' },
    { to: 'Tahoe Donner', sub: 'Mon · 6:48 AM', mi: '184', mn: '215' },
  ];
  return (
    <MiniScreen w={258} h={250} pad={14}>
      <div style={{ fontSize: 11, fontWeight: 600, color: T.textMuted, letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 12 }}>Recent drives</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
        {rows.map((r, i) =>
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '10px 12px', borderRadius: 14,
            background: 'rgba(255,255,255,0.05)', border: '0.5px solid rgba(255,255,255,0.08)' }}>
            <div style={{ width: 30, height: 30, borderRadius: 9, background: 'rgba(201,168,76,0.12)', flexShrink: 0,
              display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <SFIcon name="location.fill" size={15} color={T.gold}/>
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: T.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{r.to}</div>
              <div style={{ fontSize: 10.5, color: T.textMuted, marginTop: 1 }}>{r.sub}</div>
            </div>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontFamily: T.fontNum, fontSize: 13, fontWeight: 600, color: T.text }}>{r.mi}<span style={{ fontSize: 9, color: T.textMuted }}> mi</span></div>
              <div style={{ fontSize: 10, color: T.textMuted, marginTop: 1 }}>{r.mn} min</div>
            </div>
          </div>)}
      </div>
    </MiniScreen>);
}

function VigSharing() {
  const people = [
    { name: 'Mira Chen', perm: 'Live location', online: true },
    { name: 'Jonas Park', perm: 'Live + history', online: true },
    { name: 'Aanya Iyer', perm: 'Live location', online: false },
  ];
  return (
    <MiniScreen w={258} h={250} pad={14}>
      <div style={{ fontSize: 11, fontWeight: 600, color: T.textMuted, letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 12 }}>People with access</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
        {people.map((p, i) =>
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '9px 12px', borderRadius: 14,
            background: 'rgba(255,255,255,0.05)', border: '0.5px solid rgba(255,255,255,0.08)' }}>
            <Avatar name={p.name} size={32} online={p.online}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: T.text }}>{p.name}</div>
              <div style={{ fontSize: 10.5, color: T.textMuted, marginTop: 1 }}>{p.perm}</div>
            </div>
            <div style={{ padding: '4px 9px', borderRadius: 10, background: 'rgba(201,168,76,0.12)', border: `0.5px solid ${T.gold}44` }}>
              <span style={{ fontSize: 9.5, fontWeight: 600, color: T.gold }}>Shared</span>
            </div>
          </div>)}
      </div>
    </MiniScreen>);
}

function VigRequest() {
  return (
    <MiniScreen w={258} h={250} pad={16}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 14 }}>
        <PulseDot color={T.gold} size={7}/>
        <span style={{ fontSize: 11, fontWeight: 600, color: T.gold, letterSpacing: 0.6, textTransform: 'uppercase' }}>Ride request</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 14 }}>
        <Avatar name="Mira Chen" size={42}/>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 15, fontWeight: 600, color: T.text }}>Mira wants a ride</div>
          <div style={{ fontSize: 11.5, color: T.textSec, marginTop: 2 }}>Cybercab · 68% battery</div>
        </div>
      </div>
      <div style={{ padding: '11px 13px', borderRadius: 14, background: 'rgba(255,255,255,0.05)', border: '0.5px solid rgba(255,255,255,0.08)', marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
          <SFIcon name="mappin" size={16} color={T.gold}/>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: T.text }}>SFO · Terminal 2</div>
            <div style={{ fontSize: 10.5, color: T.textMuted, marginTop: 1 }}>18.4 mi · ~32 min</div>
          </div>
        </div>
      </div>
      <div style={{ display: 'flex', gap: 9 }}>
        <div style={{ flex: 1, height: 40, borderRadius: 12, background: 'rgba(255,255,255,0.06)', border: '0.5px solid rgba(255,255,255,0.12)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 600, color: T.textSec }}>Decline</div>
        <div style={{ flex: 1.4, height: 40, borderRadius: 12, background: T.gold,
          display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 600, color: '#1a1408' }}>Send the car</div>
      </div>
    </MiniScreen>);
}

function VigClimate() {
  const controls = [
    { icon: 'snowflake', label: 'Cool', val: '68°', on: true },
    { icon: 'sun.max.fill', label: 'Heat', val: 'Off', on: false },
    { icon: 'lock.fill', label: 'Locked', val: '', on: true },
    { icon: 'fan', label: 'Fan', val: 'Auto', on: true },
  ];
  return (
    <MiniScreen w={258} h={250} pad={16}>
      <div style={{ fontSize: 11, fontWeight: 600, color: T.textMuted, letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 14 }}>Vehicle controls</div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 11 }}>
        {controls.map((c, i) =>
          <div key={i} style={{ padding: '13px 14px', borderRadius: 16,
            background: c.on ? 'rgba(201,168,76,0.10)' : 'rgba(255,255,255,0.04)',
            border: `0.5px solid ${c.on ? T.gold + '44' : 'rgba(255,255,255,0.08)'}` }}>
            <SFIcon name={c.icon} size={22} color={c.on ? T.gold : T.textSec}/>
            <div style={{ fontSize: 12.5, fontWeight: 600, color: T.text, marginTop: 10 }}>{c.label}</div>
            {c.val && <div style={{ fontSize: 11, color: c.on ? T.gold : T.textMuted, marginTop: 2 }}>{c.val}</div>}
          </div>)}
      </div>
    </MiniScreen>);
}

// ── Rider vignettes ──────────────────────────────────────────
function VigRequestRide() {
  return (
    <MiniScreen w={258} h={250} pad={16}>
      <div style={{ fontSize: 11, fontWeight: 600, color: T.textMuted, letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 14 }}>Where to?</div>
      <div style={{ height: 46, borderRadius: 13, background: 'rgba(255,255,255,0.06)', border: '0.5px solid rgba(255,255,255,0.12)',
        display: 'flex', alignItems: 'center', gap: 10, padding: '0 14px', marginBottom: 11 }}>
        <SFIcon name="magnifyingglass" size={16} color={T.textMuted}/>
        <span style={{ fontSize: 13.5, color: T.text }}>Ferry Building</span>
      </div>
      {['Embarcadero Plaza', 'Mission · Tartine'].map((s, i) =>
        <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '9px 4px' }}>
          <SFIcon name="mappin" size={15} color={T.textMuted}/>
          <span style={{ fontSize: 12.5, color: T.textSec }}>{s}</span>
        </div>)}
      <div style={{ height: 46, borderRadius: 13, background: T.gold, marginTop: 14,
        display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
        <SFIcon name="paperplane.fill" size={15} color="#1a1408"/>
        <span style={{ fontSize: 14, fontWeight: 600, color: '#1a1408' }}>Request ride</span>
      </div>
    </MiniScreen>);
}

function VigTrack() {
  const route = (window.buildSampleRoute && window.buildSampleRoute()) || [];
  return (
    <MiniScreen w={252} h={252}>
      <MapBackground width={252} height={252} seed={7}/>
      <svg width="252" height="252" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
        <RouteLine path={route} progress={0.34} width={6}/>
      </svg>
      <div style={{ position: 'absolute', top: '34%', left: '40%', transform: 'translate(-50%,-50%)' }}>
        <VehicleMarker heading={52} size={20}/>
      </div>
      <div style={{ position: 'absolute', left: 12, right: 12, top: 12, height: 46, borderRadius: 15,
        background: 'rgba(20,20,24,0.66)', backdropFilter: 'blur(18px)', border: '0.5px solid rgba(255,255,255,0.12)',
        display: 'flex', alignItems: 'center', padding: '0 14px', gap: 10 }}>
        <div style={{ width: 28, height: 28, borderRadius: 8, background: 'rgba(201,168,76,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <SFIcon name="car.fill" size={15} color={T.gold}/>
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: T.text }}>Alex's Model Y</div>
          <div style={{ fontSize: 10, color: T.textSec }}>On the way to you</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontFamily: T.fontNum, fontSize: 18, fontWeight: 500, color: T.gold }}>3</div>
          <div style={{ fontSize: 8.5, color: T.gold, fontWeight: 600, letterSpacing: 0.6 }}>MIN</div>
        </div>
      </div>
    </MiniScreen>);
}

function VigRideHistory() {
  const rows = [
    { to: 'Ferry Building', sub: 'Today · with Alex', mi: '4.2' },
    { to: 'SFO · Terminal 2', sub: 'Fri · with Mom', mi: '18.4' },
    { to: 'Mission · Tartine', sub: 'Tue · with Alex', mi: '3.8' },
  ];
  return (
    <MiniScreen w={258} h={250} pad={14}>
      <div style={{ fontSize: 11, fontWeight: 600, color: T.textMuted, letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 12 }}>Your rides</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
        {rows.map((r, i) =>
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '10px 12px', borderRadius: 14,
            background: 'rgba(255,255,255,0.05)', border: '0.5px solid rgba(255,255,255,0.08)' }}>
            <div style={{ width: 30, height: 30, borderRadius: 9, background: 'rgba(201,168,76,0.12)', flexShrink: 0,
              display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <SFIcon name="clock.fill" size={15} color={T.gold}/>
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: T.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{r.to}</div>
              <div style={{ fontSize: 10.5, color: T.textMuted, marginTop: 1 }}>{r.sub}</div>
            </div>
            <div style={{ fontFamily: T.fontNum, fontSize: 13, fontWeight: 600, color: T.text }}>{r.mi}<span style={{ fontSize: 9, color: T.textMuted }}> mi</span></div>
          </div>)}
      </div>
    </MiniScreen>);
}

function VigSharedWith() {
  const fleet = (window.FLEET || []).slice(0, 3);
  const fallback = [
    { owner: 'Alex', rel: 'Roommate', name: 'Model Y' },
    { owner: 'Mom', rel: 'Family', name: 'Model Y' },
    { owner: 'Jordan', rel: 'Friend', name: 'Model 3' },
  ];
  const list = fleet.length ? fleet : fallback;
  return (
    <MiniScreen w={258} h={250} pad={14}>
      <div style={{ fontSize: 11, fontWeight: 600, color: T.textMuted, letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 12 }}>Cars you can ride</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
        {list.map((f, i) =>
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '10px 12px', borderRadius: 14,
            background: 'rgba(255,255,255,0.05)', border: '0.5px solid rgba(255,255,255,0.08)' }}>
            <Avatar name={f.owner} size={32}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: T.text }}>{f.owner}'s {f.name}</div>
              <div style={{ fontSize: 10.5, color: T.textMuted, marginTop: 1 }}>{f.rel}</div>
            </div>
            <SFIcon name="car.fill" size={18} color={T.gold}/>
          </div>)}
      </div>
    </MiniScreen>);
}

function VigSafety() {
  const can = ['Request rides', 'Watch the live map & ETA', 'See your ride history'];
  const cant = ['Unlock or drive the car', 'Change vehicle settings'];
  return (
    <MiniScreen w={258} h={250} pad={16}>
      <div style={{ fontSize: 11, fontWeight: 600, color: T.driving, letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 10 }}>You can</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginBottom: 16 }}>
        {can.map((c, i) =>
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <SFIcon name="checkmark" size={15} color={T.driving} weight={2.4}/>
            <span style={{ fontSize: 13, color: T.text }}>{c}</span>
          </div>)}
      </div>
      <div style={{ fontSize: 11, fontWeight: 600, color: T.textMuted, letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 10 }}>You can't</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {cant.map((c, i) =>
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <SFIcon name="lock.fill" size={14} color={T.textMuted}/>
            <span style={{ fontSize: 13, color: T.textSec }}>{c}</span>
          </div>)}
      </div>
    </MiniScreen>);
}

// ─────────────────────────────────────────────────────────────
// StoryDeck — the paged carousel.
// ─────────────────────────────────────────────────────────────
function StoryDeck({ cards, onDone, cta = 'Get Started', kicker }) {
  const [i, setI] = tS(0);
  const [dir, setDir] = tS(1);
  const drag = tR(null);
  const last = i === cards.length - 1;

  const go = (n) => { if (n < 0 || n >= cards.length) return; setDir(n > i ? 1 : -1); setI(n); };
  const next = () => last ? onDone() : go(i + 1);

  const onDown = (e) => { drag.current = e.clientX; };
  const onUp = (e) => {
    if (drag.current == null) return;
    const dx = e.clientX - drag.current; drag.current = null;
    if (dx < -46) go(i + 1); else if (dx > 46) go(i - 1);
  };

  const card = cards[i];
  return (
    <div style={{ height: '100%', background: T.bg, position: 'relative', overflow: 'hidden' }}>
      <style>{`
        @keyframes mrtVigFloat { 0%,100% { transform: translateY(0); } 50% { transform: translateY(-9px); } }
        @keyframes mrtStoryInR { from { opacity: 0; transform: translateX(34px); } to { opacity: 1; transform: none; } }
        @keyframes mrtStoryInL { from { opacity: 0; transform: translateX(-34px); } to { opacity: 1; transform: none; } }
      `}</style>
      <GoldWash/>

      {/* Skip */}
      {!last && <TopAction label="Skip" onClick={onDone}/>}

      {/* kicker / brand */}
      <div style={{ position: 'absolute', top: 84, left: 26, zIndex: 30, display: 'flex', alignItems: 'center', gap: 10 }}>
        <HexLogo size={24}/>
        <span style={{ fontSize: 13, fontWeight: 700, color: T.gold, letterSpacing: 0.6, textTransform: 'uppercase' }}>{kicker}</span>
      </div>

      {/* swipe surface */}
      <div onPointerDown={onDown} onPointerUp={onUp}
        style={{ position: 'absolute', inset: 0, paddingTop: 128, paddingBottom: 34, paddingLeft: 30, paddingRight: 30,
          display: 'flex', flexDirection: 'column', touchAction: 'pan-y' }}>
        {/* hero vignette */}
        <div key={'v' + i} style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: 0,
          animation: `${dir > 0 ? 'mrtStoryInR' : 'mrtStoryInL'} .45s cubic-bezier(0.22,1,0.36,1) both` }}>
          <div style={tFloat}>{card.visual}</div>
        </div>

        {/* text */}
        <div key={'t' + i} style={{ animation: `${dir > 0 ? 'mrtStoryInR' : 'mrtStoryInL'} .45s cubic-bezier(0.22,1,0.36,1) .05s both`, marginTop: 8 }}>
          <div style={{ fontSize: 27, fontWeight: 600, color: T.text, letterSpacing: -0.6, lineHeight: 1.12, marginBottom: 12, textWrap: 'pretty' }}>{card.title}</div>
          <div style={{ fontSize: 15, color: T.textSec, lineHeight: 1.55, maxWidth: 320, textWrap: 'pretty' }}>{card.body}</div>
        </div>

        {/* dots */}
        <div style={{ display: 'flex', gap: 7, justifyContent: 'center', margin: '26px 0 20px' }}>
          {cards.map((_, n) =>
            <button key={n} onClick={() => go(n)} style={{ border: 'none', cursor: 'pointer', padding: 0,
              width: n === i ? 22 : 7, height: 7, borderRadius: 4,
              background: n === i ? T.gold : 'rgba(255,255,255,0.2)', transition: 'all .3s ease' }}/>)}
        </div>

        <Button variant="outline-static" onClick={next}>{last ? cta : 'Continue'}</Button>
      </div>
    </div>);
}

// ── Owner & Rider tutorial decks ─────────────────────────────
function OwnerTutorial({ onDone }) {
  const cards = [
    { title: 'Your car, live.', body: 'Watch your Tesla move in real time — location, speed, battery, and status, always a glance away.', visual: <VigLiveMap/> },
    { title: 'Every drive, remembered.', body: 'Trips log automatically with routes, distance, duration, and energy used. Tap any drive for the full summary.', visual: <VigDrives/> },
    { title: 'Share with people you trust.', body: 'Invite family and friends to watch the live map or request rides — you control exactly what each person can see and do.', visual: <VigSharing/> },
    { title: 'Send the car to anyone.', body: 'Get a ride request, glance at the destination and battery, and dispatch your Tesla with a single tap.', visual: <VigRequest/> },
    { title: 'Comfort, before you’re in.', body: 'Pre-condition the cabin, lock or unlock, and control media — all from your phone, wherever you are.', visual: <VigClimate/> },
  ];
  return <StoryDeck cards={cards} onDone={onDone} kicker="Getting started" cta="Go to my car"/>;
}

function RiderTutorial({ onDone }) {
  const cards = [
    { title: 'Request a ride in seconds.', body: 'Pick a destination and ask for the car — the owner gets your request instantly and can send it your way.', visual: <VigRequestRide/> },
    { title: 'Track every minute.', body: 'Follow the Tesla on the map with a live ETA, from the moment it’s on its way to the second it arrives.', visual: <VigTrack/> },
    { title: 'Your rides, saved.', body: 'Revisit past trips with routes, times, distance, and who you rode with.', visual: <VigRideHistory/> },
    { title: 'Cars shared with you.', body: 'See whose vehicles you can ride in and what each owner has allowed — all in one place.', visual: <VigSharedWith/> },
    { title: 'Clear boundaries.', body: 'As a guest you can request rides and watch the live map — never unlock or drive the car. The owner always stays in charge.', visual: <VigSafety/> },
  ];
  return <StoryDeck cards={cards} onDone={onDone} kicker="Welcome aboard" cta="Start riding"/>;
}

Object.assign(window, { StoryDeck, OwnerTutorial, RiderTutorial });
