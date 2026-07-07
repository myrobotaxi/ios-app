// MyRoboTaxi prototype app — orchestrates 8 screens inside iPhone 17 Pro
// with a Tweaks panel for live state manipulation.

const { useState: aS, useEffect: aE, useMemo: aM, useRef: aR } = React;

const SCREEN_HEIGHT = 874;

function App() {
  // Tweaks (persisted to source via __edit_mode_set_keys)
  const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
    "design": "liquid",
    "vehicleState": "driving",
    "riderName": "Sam",
    "tripProgress": 0.42,
    "battery": 68,
    "speed": 64,
    "diState": "compact",
    "diExpandedStyle": "flighty",
    "parkedStyle": "floating",
    "liveActivityStyle": "pill"
  } /*EDITMODE-END*/;
  const [tweaks, setTweak] = useTweaks(TWEAK_DEFAULTS);

  // Navigation state
  const [role, setRole] = aS('owner'); // owner | shared — top-level flow
  const [screen, setScreen] = aS('driveSummary'); // signin, empty, home, drives, driveSummary, invites, settings, shared, rideHistory, sharedSettings
  const [nav, setNav] = aS('driveSummary'); // home, drives, invites, settings (owner bottom-nav tab)
  const [sheet, setSheet] = aS('peek'); // peek | half
  const [vehicleIdx, setVehicleIdx] = aS(0);
  const [drivingDriveId, setDriveId] = aS('d9');
  const [sharedDrive, setSharedDrive] = aS(null); // shared completed ride opened in the summary
  const [inviteFrom, setInviteFrom] = aS(null); // where the invite-code flow was launched from

  // Ride-request feature state (cross-side)
  const [requestState, setRequestState] = aS('idle'); // idle | pending | accepted | rejected
  const [requestDest, setRequestDest] = aS(null); // { id, label, sub, miles, mins, ... }
  const [requestPassenger, setRequestPassenger] = aS(null); // { name, phone } when riding for someone else | null
  const [sentToast, setSentToast] = aS(false);
  const [requestKind, setRequestKind] = aS('now'); // now | scheduled — type of incoming request
  const [requestSchedule, setRequestSchedule] = aS(null); // { day, time } for scheduled requests
  // Owner's confirmed upcoming scheduled rides (seeded with a couple)
  const [ownerUpcoming, setOwnerUpcoming] = aS([
  { id: 'ou1', rider: 'Mira', dest: { label: 'SFO · Terminal 2', sub: 'San Francisco International', miles: 18.4, mins: 32 }, schedule: { day: 'Tomorrow', time: '6:40 AM' }, vehicle: 'Cybercab' },
  { id: 'ou2', rider: 'Jonas', dest: { label: 'Tahoe Donner', sub: 'Truckee', miles: 184, mins: 215 }, schedule: { day: 'Sat', time: '7:00 AM' }, vehicle: 'Cybercab' }]
  );

  const driving = tweaks.vehicleState === 'driving';
  const charging = tweaks.vehicleState === 'charging';

  // Auto-advance simulated speed when driving (ambient motion)
  aE(() => {
    if (!driving) return;
    const id = setInterval(() => {
      const target = 55 + Math.sin(Date.now() / 4000) * 18;
      // Smooth toward target without invoking setTweak's persistence (avoid spam)
      // We mutate the visible speed via a separate live state
    }, 800);
    return () => clearInterval(id);
  }, [driving]);

  // Map bottom-nav to screen change
  aE(() => {
    if (['home', 'drives', 'invites', 'settings'].includes(nav)) setScreen(nav);
  }, [nav]);

  const goto = (s) => {setScreen(s);if (['home', 'drives', 'invites', 'settings'].includes(s)) setNav(s);};

  // Switch top-level flow and land on that flow's home
  const switchRole = (r) => {
    setRole(r);
    if (r === 'owner') {setScreen('home');setNav('home');} else
    {setScreen('shared');}
  };

  // Decide DI state from screen + tweaks
  // If user is on home screen, DI hides into minimal (system convention).
  // If on any other screen with driving, show compact or expanded.
  const onScreen = ['drives', 'driveSummary', 'invites', 'settings'].includes(screen);
  const diState = driving && onScreen ? tweaks.diState : driving ? 'minimal' : 'minimal';
  const eta = Math.max(1, Math.round((1 - tweaks.tripProgress) * 87));

  // Cycle DI on tap from compact → expanded → compact
  const cycleDI = () => {
    if (!onScreen || !driving) return;
    setTweak('diState', tweaks.diState === 'compact' ? 'expanded' : 'compact');
  };

  let content;
  if (screen === 'signin') {
    content = <SignInScreen onSignIn={() => goto(role === 'shared' ? 'shared' : 'home')} />;
  } else if (screen === 'empty') {
    content = <EmptyScreen onAdd={() => goto('addTesla')} onInvite={() => { setInviteFrom('empty'); goto('inviteCode'); }} />;
  } else if (screen === 'addTesla') {
    content = <AddTeslaFlow onComplete={() => goto('ownerTutorial')} onCancel={() => goto('empty')} />;
  } else if (screen === 'ownerTutorial') {
    content = <OwnerTutorial onDone={() => { setRole('owner'); setScreen('home'); setNav('home'); }} />;
  } else if (screen === 'inviteCode') {
    content = <InviteCodeFlow
      onComplete={() => { if (inviteFrom === 'sharedSettings') { setRole('shared'); setScreen('sharedSettings'); } else { goto('riderTutorial'); } }}
      onCancel={() => { if (inviteFrom === 'sharedSettings') { setRole('shared'); setScreen('sharedSettings'); } else { goto('empty'); } }}
      returning={inviteFrom === 'sharedSettings'} />;
  } else if (screen === 'riderTutorial') {
    content = <RiderTutorial onDone={() => switchRole('shared')} />;
  } else if (screen === 'home') {
    content = <HomeScreen
      vehicleIdx={vehicleIdx} setVehicleIdx={setVehicleIdx}
      sheet={sheet} setSheet={setSheet}
      driving={driving} progress={tweaks.tripProgress} battery={tweaks.battery} speed={tweaks.speed}
      parkedStyle={tweaks.parkedStyle}
      nav={nav} setNav={(k) => {setNav(k);}} mapHeight={SCREEN_HEIGHT} />;
  } else if (screen === 'drives') {
    content = <DrivesScreen nav={nav} setNav={setNav} onOpenDrive={(id) => {setDriveId(id);setScreen('driveSummary');}} driving={driving} upcoming={ownerUpcoming} onCancelUpcoming={(id) => setOwnerUpcoming((u) => u.filter((x) => x.id !== id))} />;
  } else if (screen === 'driveSummary') {
    content = <DriveSummaryScreen driveId={drivingDriveId} onBack={() => setScreen('drives')} />;
  } else if (screen === 'invites') {
    content = <InvitesScreen nav={nav} setNav={setNav} />;
  } else if (screen === 'settings') {
    content = <SettingsScreen nav={nav} setNav={setNav} onAddTesla={() => goto('addTesla')} onSignOut={() => { setNav('signin'); setScreen('signin'); }} />;
  } else if (screen === 'shared') {
    content = <SharedViewerScreen progress={tweaks.tripProgress} battery={tweaks.battery} speed={tweaks.speed} driving={driving}
    riderName={tweaks.riderName}
    requestState={requestState} setRequestState={setRequestState}
    requestDest={requestDest} setRequestDest={setRequestDest}
    requestPassenger={requestPassenger} setRequestPassenger={setRequestPassenger}
    nav={screen} setNav={goto} />;
  } else if (screen === 'rideHistory') {
    content = <RideHistoryScreen nav={screen} setNav={goto} riderName={tweaks.riderName} onOpenRide={(r) => { setSharedDrive(r); setScreen('rideSummary'); }} />;
  } else if (screen === 'rideSummary') {
    content = <DriveSummaryScreen drive={sharedDrive} onBack={() => setScreen('rideHistory')} />;
  } else if (screen === 'sharedSettings') {
    content = <SharedSettingsScreen nav={screen} setNav={goto} riderName={tweaks.riderName} onAddCode={() => { setInviteFrom('sharedSettings'); setScreen('inviteCode'); }} onSignOut={() => { setScreen('signin'); }} />;
  }

  // Owner-side accept handler: now → dispatch & drive; scheduled → reserve for later
  const handleOwnerAccept = () => {
    setSentToast(true);
    if (requestKind === 'scheduled' && requestSchedule) {
      setOwnerUpcoming((u) => [{ id: 'ou' + Date.now(), rider: tweaks.riderName || 'Sam', dest: requestDest, schedule: requestSchedule, vehicle: VEHICLES[vehicleIdx].name }, ...u]);
      setRequestState('accepted');
    } else {
      setRequestState('accepted');
      setTweak({ vehicleState: 'driving', tripProgress: 0.04, speed: 22 });
    }
    setTimeout(() => setSentToast(false), 4200);
  };
  const handleOwnerReject = () => {setRequestState('rejected');};

  // Show incoming request sheet only on the owner flow (not viewer/sign-in)
  const isOwnerSurface = role === 'owner' && screen !== 'signin';
  const sheetVisible = isOwnerSurface && requestState === 'pending';

  // Wrap the phone in a frame that allows a custom DI
  const di =
  <DynamicIsland state={diState} expandedStyle={tweaks.diExpandedStyle}
  vehicle={VEHICLES[vehicleIdx].name}
  status={tweaks.vehicleState} eta={eta} battery={tweaks.battery} speed={tweaks.speed}
  progress={tweaks.tripProgress}
  onLongPress={() => goto('home')} />;


  return (
    <DesignCtx.Provider value={tweaks.design}>
    <div style={{
        width: '100vw', minHeight: '100vh', background: '#0c0c0e',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: '40px 24px', boxSizing: 'border-box',
        fontFamily: T.font, color: T.text,
        backgroundImage: 'radial-gradient(ellipse at 30% 0%, rgba(201,168,76,0.06), transparent 50%), radial-gradient(ellipse at 80% 100%, rgba(48,209,88,0.04), transparent 50%)'
      }}>
      <MRTStyles />
      <style>{`@keyframes mrtScreenIn { from { opacity: 0; transform: scale(0.985); } to { opacity: 1; transform: scale(1); } }`}</style>
      <PrototypeChrome screen={screen} goto={goto} role={role} onRole={switchRole} design={tweaks.design} onDesign={(v) => setTweak('design', v)} />
      <div style={{ cursor: 'default' }}>
        <Phone17Pro>
          <div key={screen} style={{ height: '100%', animation: 'mrtScreenIn 0.5s cubic-bezier(0.22,1,0.36,1) both' }}>
            {content}
          </div>
          {/* Owner-side incoming ride-request sheet */}
          <IncomingRequestSheet visible={sheetVisible}
            requesterName={tweaks.riderName || 'Sam'} dest={requestDest} vehicleName={VEHICLES[vehicleIdx].name}
            battery={tweaks.battery} kind={requestKind} schedule={requestSchedule} passenger={requestPassenger}
            onAccept={handleOwnerAccept} onReject={handleOwnerReject} />
          {/* Owner-side toast after accept */}
          <RouteSentToast visible={sentToast && isOwnerSurface}
            vehicleName={VEHICLES[vehicleIdx].name} dest={requestDest}
            kind={requestKind} schedule={requestSchedule} rider={tweaks.riderName || 'Sam'} passenger={requestPassenger} />
          {/* Custom DI replaces default one */}
          {di}
        </Phone17Pro>
      </div>
      <TweaksPanel title="Tweaks">
        <TweakSection title="Appearance">
          <TweakRadio label="Design" value={tweaks.design} onChange={(v) => setTweak('design', v)}
            options={[{ value: 'flat', label: 'Flat' }, { value: 'liquid', label: 'Liquid Glass' }]} />
        </TweakSection>
        <TweakSection title="Vehicle">
          <TweakRadio label="State" value={tweaks.vehicleState} onChange={(v) => setTweak('vehicleState', v)}
            options={[{ value: 'parked', label: 'Parked' }, { value: 'driving', label: 'Driving' }, { value: 'charging', label: 'Charging' }]} />
        </TweakSection>
        <TweakSection title="Trip">
          <TweakRadio label="Tracking stage" value={tweaks.tripProgress >= 0.999 ? 'complete' : tweaks.tripProgress < 0.16 ? 'pickup' : tweaks.tripProgress > 0.93 ? 'arriving' : 'inride'}
            onChange={(v) => setTweak('tripProgress', v === 'pickup' ? 0.06 : v === 'arriving' ? 0.95 : v === 'complete' ? 1 : 0.55)}
            options={[
              { value: 'pickup', label: 'To pickup' },
              { value: 'inride', label: 'In ride' },
              { value: 'arriving', label: 'Arriving' },
              { value: 'complete', label: 'Complete' },
            ]} />
          <TweakSlider label="Trip progress" min={0.02} max={1} step={0.01} value={tweaks.tripProgress} onChange={(v) => setTweak('tripProgress', v)} format={(v) => `${Math.round(v * 100)}%`} />
          <TweakSlider label="Battery" min={5} max={100} step={1} value={tweaks.battery} onChange={(v) => setTweak('battery', v)} format={(v) => `${v}%`} />
          <TweakSlider label="Speed" min={0} max={85} step={1} value={tweaks.speed} onChange={(v) => setTweak('speed', v)} format={(v) => `${v} mph`} />
        </TweakSection>
        <TweakSection title="Dynamic Island">
          <TweakRadio label="State" value={tweaks.diState} onChange={(v) => setTweak('diState', v)}
            options={[{ value: 'compact', label: 'Compact' }, { value: 'expanded', label: 'Expanded' }, { value: 'minimal', label: 'Minimal' }]} />
          <TweakSelect label="Expanded layout" value={tweaks.diExpandedStyle} onChange={(v) => setTweak('diExpandedStyle', v)}
            options={[
            { value: 'flighty', label: 'Flighty — progress + 3 stats' },
            { value: 'uber', label: 'Uber — map + primary ETA' },
            { value: 'detailed', label: 'Detailed — map + 3 stat rows (orig.)' }]
            } />
          <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.5)', marginTop: 4 }}>Long-press the island to deep-link to /home. (Right-click in this prototype.)</div>
        </TweakSection>
        <TweakSection title="Parked state">
          <TweakSelect label="Map vs. info" value={tweaks.parkedStyle} onChange={(v) => setTweak('parkedStyle', v)}
            options={[
            { value: 'floating', label: 'Floating card — map-first' },
            { value: 'pill', label: 'Pill — minimal' },
            { value: 'sheet', label: 'Bottom sheet (orig.)' }]
            } />
        </TweakSection>
        <TweakSection title="Drives ‘now’ sticky">
          <TweakSelect label="Style" value={tweaks.liveActivityStyle} onChange={(v) => setTweak('liveActivityStyle', v)}
            options={[
            { value: 'pill', label: 'Pill — single line' },
            { value: 'mini', label: 'Mini-card — with progress' },
            { value: 'full', label: 'Full card (orig.)' },
            { value: 'none', label: 'Hidden — top banner only' }]
            } />
        </TweakSection>
        <TweakSection title="Ride request">
          <TweakText label="Rider name" value={tweaks.riderName} onChange={(v) => setTweak('riderName', v || 'Sam')} placeholder="Sam" />
          <TweakRadio label="Viewer ride state" value={requestState} onChange={(v) => {
              if (v !== 'idle' && !requestDest) {
                setRequestKind('now'); setRequestSchedule(null);
                setRequestDest({ id: 'pescadero', label: "Duarte's Tavern", sub: '202 Stage Rd · Pescadero', miles: 41.2, mins: 87 });
              }
              setRequestState(v);
              if (v !== 'idle') switchRole('shared');
            }}
            options={[
            { value: 'idle', label: 'Idle' },
            { value: 'pending', label: 'Pending' },
            { value: 'accepted', label: 'Accepted' },
            { value: 'rejected', label: 'Declined' }]
            } />
          <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.5)', marginTop: 4, lineHeight: 1.45 }}>
            Drives the rider’s live view: <b>Pending</b> = request sent / waiting, <b>Accepted</b> = track the ride with a live ETA & arrival time, <b>Declined</b> = request turned down.
          </div>
          <TweakButton label="Start viewer flow →" onClick={() => {
              setRequestState('idle');
              setRequestDest(null);
              setRequestPassenger(null);
              switchRole('shared');
            }} />
          <TweakButton label="Simulate now request (owner)" onClick={() => {
              setRequestKind('now');setRequestSchedule(null);
              setRequestDest({ id: 'pescadero', label: "Duarte's Tavern", sub: '202 Stage Rd · Pescadero', miles: 41.2, mins: 87 });
              setRequestState('pending');
              switchRole('owner');
            }} />
          <TweakButton label="Simulate scheduled request (owner)" onClick={() => {
              setRequestKind('scheduled');setRequestSchedule({ day: 'Fri', time: '5:30 PM' });
              setRequestDest({ id: 'sfo', label: 'SFO · Terminal 2', sub: 'San Francisco International', miles: 18.4, mins: 32 });
              setRequestState('pending');
              switchRole('owner');
            }} />
          <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.5)', marginTop: 4, lineHeight: 1.45 }}>
            Owner gets the request sheet (now → dispatches immediately; scheduled → reserves the car for later, shown under Drives → Upcoming).
          </div>
        </TweakSection>
        <TweakSection title="Jump to screen">
          <TweakSelect value={screen} onChange={(v) => goto(v)}
            options={[
            { value: 'signin', label: 'Sign In' }, { value: 'empty', label: 'Empty State' },
            { value: 'addTesla', label: 'Add Tesla — pairing' }, { value: 'ownerTutorial', label: 'Owner tutorial' },
            { value: 'inviteCode', label: 'Invite code — join' }, { value: 'riderTutorial', label: 'Rider tutorial' },
            { value: 'home', label: 'Live Map (home)' }, { value: 'drives', label: 'Drive History' },
            { value: 'driveSummary', label: 'Drive Summary' }, { value: 'invites', label: 'Invites / Share' },
            { value: 'settings', label: 'Settings' }, { value: 'shared', label: 'Shared Viewer (anon)' }]
            } />
        </TweakSection>
      </TweaksPanel>
    </div>
    </DesignCtx.Provider>);

}

function PrototypeChrome({ screen, goto, role, onRole, design, onDesign }) {
  const ownerScreens = [
  ['home', 'Vehicle'], ['drives', 'Drives'], ['invites', 'Share'], ['settings', 'Settings'],
  ['signin', 'Sign In'], ['empty', 'Empty'], ['addTesla', 'Add Tesla'], ['ownerTutorial', 'Owner Tutorial'], ['driveSummary', 'Drive Summary']];

  const sharedScreens = [
  ['signin', 'Sign In'], ['inviteCode', 'Invite Code'], ['riderTutorial', 'Rider Tutorial'], ['shared', 'Live Map'], ['rideHistory', 'Ride History'], ['sharedSettings', 'Settings']];

  const screens = role === 'owner' ? ownerScreens : sharedScreens;
  return (
    <div style={{
      position: 'fixed', top: 16, left: 16, zIndex: 1000,
      padding: '14px 18px', borderRadius: 18,
      background: 'rgba(20,20,22,0.85)', backdropFilter: 'blur(20px) saturate(180%)',
      border: '0.5px solid rgba(255,255,255,0.08)',
      maxWidth: 280, color: T.text
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
        <HexLogo size={22} />
        <Wordmark size={15} />
      </div>
      {/* Role switch — Owner vs Shared flow */}
      <div style={{ fontSize: 10, color: T.gold, letterSpacing: 1.2, marginBottom: 7, textTransform: 'uppercase', fontWeight: 600 }}>Flow</div>
      <div style={{ display: 'flex', gap: 4, padding: 3, borderRadius: 11, background: 'rgba(255,255,255,0.05)', marginBottom: 14 }}>
        {[['owner', 'Owner'], ['shared', 'Shared']].map(([k, label]) =>
        <button key={k} onClick={() => onRole(k)} style={{
          flex: 1, padding: '7px 6px', borderRadius: 8, border: 'none', cursor: 'pointer',
          fontFamily: T.font, fontSize: 12.5, fontWeight: 600, letterSpacing: -0.1,
          background: role === k ? T.gold : 'transparent',
          color: role === k ? '#1a1408' : T.textSec
        }}>{label}</button>
        )}
      </div>
      <div style={{ fontSize: 10.5, color: T.textMuted, marginBottom: 14, lineHeight: 1.45 }}>
        {role === 'owner' ?
        'Full vehicle control — climate, media, status, drives, sharing.' :
        'Guest view — request a ride, watch the live map, see your ride history.'}
      </div>
      <div style={{ fontSize: 10, color: T.gold, letterSpacing: 1.2, marginBottom: 7, textTransform: 'uppercase', fontWeight: 600 }}>Appearance</div>
      <DesignToggle value={design} onChange={onDesign} />
      <div style={{ fontSize: 10, color: T.textMuted, letterSpacing: 1.2, margin: '14px 0 8px', textTransform: 'uppercase', fontWeight: 500 }}>{role === 'owner' ? 'Owner screens' : 'Shared screens'}</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
        {screens.map(([k, label]) =>
        <button key={k} onClick={() => goto(k)} style={{
          background: screen === k ? `${T.gold}22` : 'transparent',
          border: 'none', padding: '6px 10px', borderRadius: 8,
          color: screen === k ? T.gold : T.textSec, fontSize: 12,
          fontFamily: T.font, fontWeight: 500, textAlign: 'left',
          cursor: 'pointer'
        }}>{label}</button>
        )}
      </div>
      <div style={{ marginTop: 12, padding: '10px 0 0', borderTop: '0.5px solid rgba(255,255,255,0.08)', fontSize: 11, color: T.textMuted, lineHeight: 1.5 }}>
        Open <a href="surfaces.html" style={{ color: T.gold, textDecoration: 'none' }}>surfaces canvas →</a> for widgets, Dynamic Island, and Live Activity states.
        <div style={{ marginTop: 6 }}>
          <a href="Design System.html" style={{ color: T.gold, textDecoration: 'none' }}>Design system spec →</a> · <a href="Anatomy.html" style={{ color: T.gold, textDecoration: 'none' }}>screen anatomy →</a>
        </div>
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Inline Live Activity hint (peek of Lock Screen LA, overlaid on phone
// when user is not on map and vehicle is driving).
// ─────────────────────────────────────────────────────────────
function LiveActivityHint({ vehicle, progress, battery, speed, eta, variant = 'pill' }) {
  const S = useSurfaces();
  const baseGlass = {
    ...S.banner,
    animation: 'mrt-fade-up .5s ease-out both'
  };

  if (variant === 'pill') {
    return (
      <div style={{
        ...baseGlass,
        position: 'absolute', left: 12, right: 12, bottom: 76, zIndex: 35,
        height: 58, borderRadius: 30, padding: '0 18px 0 12px',
        display: 'flex', alignItems: 'center', gap: 12,
        pointerEvents: 'none'
      }}>
        <div style={{
          width: 36, height: 36, borderRadius: 18,
          background: 'rgba(201,168,76,0.14)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          border: `0.5px solid ${T.gold}33`
        }}>
          <ArrowMark size={18} />
        </div>
        <div style={{ flex: 1, minWidth: 0, lineHeight: 1.15 }}>
          <div style={{ fontSize: 13.5, fontWeight: 600, color: T.text, letterSpacing: -0.15, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }} data-comment-anchor="69a7c4d822-span-28-5">
            {vehicle} <span style={{ color: T.textMuted, margin: '0 5px', fontWeight: 400 }}>→</span> Pescadero
          </div>
          <div style={{ fontSize: 11, color: T.textSec, marginTop: 2, display: 'flex', alignItems: 'center', gap: 6, fontVariantNumeric: 'tabular-nums' }}>
            <span style={{ width: 5, height: 5, borderRadius: 3, background: T.driving, boxShadow: `0 0 6px ${T.driving}` }} />
            En route · {speed} mph · {Math.round(battery)}%
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontFamily: T.fontNum, fontSize: 20, fontWeight: 500, color: T.gold, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.5, lineHeight: 1 }}>
            {eta}
          </div>
          <div style={{ fontSize: 9, color: T.gold, opacity: 0.65, letterSpacing: 0.8, fontWeight: 600, marginTop: 3, textTransform: 'uppercase' }}>min</div>
        </div>
      </div>);

  }

  if (variant === 'mini') {
    return (
      <div style={{
        ...baseGlass,
        position: 'absolute', left: 12, right: 12, bottom: 76, zIndex: 35,
        borderRadius: 22, padding: '12px 16px',
        pointerEvents: 'none'
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
          <HexLogo size={18} />
          <div style={{ flex: 1, fontSize: 13, fontWeight: 500, color: T.text, letterSpacing: -0.1 }}>
            {vehicle} <span style={{ color: T.textMuted, margin: '0 5px', fontWeight: 400 }}>→</span> Pescadero
          </div>
          <div style={{ fontFamily: T.fontNum, fontSize: 15, fontWeight: 500, color: T.gold, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.2 }}>
            {eta}<span style={{ fontSize: 10, color: T.gold, opacity: 0.65, marginLeft: 2 }}>min</span>
          </div>
        </div>
        <TripProgressBar progress={progress} stops={STOPS_SAMPLE} compact />
      </div>);

  }

  // 'full' (original)
  return (
    <div style={{
      ...baseGlass,
      position: 'absolute', left: 16, right: 16, bottom: 84, zIndex: 35,
      background: 'rgba(20,20,22,0.65)',
      borderRadius: 22, padding: '14px 16px',
      pointerEvents: 'none'
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
        <HexLogo size={20} />
        <span style={{ fontSize: 11, color: T.textMuted, fontWeight: 500, letterSpacing: 0.6, textTransform: 'uppercase', flex: 1 }}>MyRoboTaxi · Now</span>
        <StatusBadge status="driving" size={10} />
      </div>
      <div style={{ fontSize: 14, fontWeight: 500, color: T.text, marginBottom: 10 }}>{vehicle} <span style={{ color: T.textMuted, margin: '0 6px' }}>→</span> <span style={{ color: T.gold }}>Pescadero</span></div>
      <TripProgressBar progress={progress} stops={STOPS_SAMPLE} compact />
      <div style={{ display: 'flex', gap: 12, marginTop: 10, fontFamily: T.fontNum }}>
        {[['ETA', eta, 'min'], ['Speed', speed, 'mph'], ['Battery', Math.round(battery), '%']].map(([l, v, u], i) =>
        <div key={i} style={{ flex: 1 }}>
            <div style={{ fontSize: 9, color: T.textMuted, letterSpacing: 0.8, textTransform: 'uppercase', fontWeight: 500 }}>{l}</div>
            <div style={{ fontSize: 14, fontWeight: 500, color: T.text, marginTop: 2, fontVariantNumeric: 'tabular-nums' }}>{v}<span style={{ color: T.textMuted, fontSize: 11, marginLeft: 2 }}>{u}</span></div>
          </div>
        )}
      </div>
    </div>);

}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);