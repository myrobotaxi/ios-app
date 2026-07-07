// MyRoboTaxi — the 8 screens. Each is a self-contained component receiving
// app state via props. Map + bottom sheet live in HomeScreen.

const { useState: uS, useEffect: uE, useMemo: uM, useRef: uR } = React;

// ─────────────────────────────────────────────────────────────
// Mock data (one vehicle, recent drives, viewers)
// ─────────────────────────────────────────────────────────────
const VEHICLES = [
  { id: 'v1', name: 'Cybercab',  model: '2026 Tesla Cybercab', color: 'Mercury Silver', plate: 'RBO-2046', seats: { heat: true, vent: true } },
  { id: 'v2', name: 'Daily',     model: '2024 Model 3 LR',     color: 'Pearl White',    plate: 'CTX-9417', seats: { heat: true, vent: false } },
];

// Shared fleet — Teslas friends & family have shared with the viewer (Sam)
const FLEET = [
  { id: 'alex',   owner: 'Alex',   rel: 'Roommate', name: 'Model Y',  model: '2025 Tesla Model Y', battery: 68, etaMin: 3,  color: 'Quicksilver', plate: 'RBO-2046' },
  { id: 'mom',    owner: 'Mom',    rel: 'Family',   name: 'Model Y',  model: '2025 Tesla Model Y',  battery: 91, etaMin: 8,  color: 'Pearl White',    plate: '8XKA113' },
  { id: 'jordan', owner: 'Jordan', rel: 'Friend',   name: 'Model 3',  model: '2024 Tesla Model 3',  battery: 54, etaMin: 12, color: 'Midnight Silver', plate: '6PCV890' },
];

const STOPS_SAMPLE = [
  { name: 'Pacifica',         at: 0.18 },
  { name: 'Half Moon Bay',    at: 0.45, kind: 'charge' },
  { name: 'Pescadero',        at: 0.78 },
];

const DRIVES = [
  { id: 'd9', date: 'today',     start: '7:42 AM', end: '8:11 AM', from: 'Home', to: 'Embarcadero Center', miles: 14.6, mins: 29, fsd: 14.2, chg: -6 },
  { id: 'd8', date: 'today',     start: '5:18 PM', end: '5:54 PM', from: 'Embarcadero Center', to: 'Mission · Tartine', miles: 3.8, mins: 36, fsd: 3.8, chg: -2 },
  { id: 'd7', date: 'yesterday', start: '9:02 AM', end: '10:34 AM', from: 'Home', to: 'Half Moon Bay · Sam\'s', miles: 28.4, mins: 92, fsd: 27.9, chg: -12 },
  { id: 'd6', date: 'yesterday', start: '2:21 PM', end: '4:08 PM', from: 'Half Moon Bay · Sam\'s', to: 'Home', miles: 29.1, mins: 107, fsd: 28.6, chg: -13 },
  { id: 'd5', date: 'Mon, May 4',start: '6:48 AM', end: '7:55 AM', from: 'Home', to: 'Tahoe Donner', miles: 184, mins: 215, fsd: 178, chg: -52 },
];

const VIEWERS = [
  { name: 'Mira Chen',       email: 'mira@chen.co',     online: true,  perm: 'Live location' },
  { name: 'Jonas Park',      email: 'jonas.park@hey',   online: true,  perm: 'Live + history' },
  { name: 'Aanya Iyer',      email: 'aanya@iyer.dev',   online: false, perm: 'Live location' },
];
const PENDING = [
  { name: 'Diego Vega',  email: 'd.vega@studio.io', sent: '2d ago' },
];

// Sample route in MAP svg space — passes through stops at given progress.
function buildSampleRoute() {
  // 12 points forming an organic coastal-ish path inside a 402×600 map.
  const raw = [[34, 92], [62, 130], [88, 170], [120, 196], [150, 234], [184, 268], [212, 304], [240, 348], [262, 388], [288, 426], [322, 462], [358, 498]];
  return raw;
}

// ─────────────────────────────────────────────────────────────
// 1 · Sign In
// ─────────────────────────────────────────────────────────────
// Glimpse of the live experience — each line assembles from gold particles,
// holds, then dissolves into the next.
const SIGNIN_GLIMPSES = [
  { t: 'Good evening', live: false },
  { t: 'A ride is 3 min away', live: true },
  { t: 'Booking ride with Thomas', live: true },
  { t: 'Heading your way', live: true },
  { t: 'Arriving', live: true },
  { t: 'Arrived, enjoy your evening', live: true },
];

function ParticleLine() {
  const ref = uR(null);
  uE(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const W = 320, H = 46, MY = H / 2 + 1;
    canvas.width = W * dpr; canvas.height = H * dpr;
    canvas.style.width = W + 'px'; canvas.style.height = H + 'px';
    const ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);
    const FONT = '500 16px ' + T.font;
    ctx.font = FONT; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';

    let mode = 'swap', t0 = performance.now();
    const HOLD = 1050, SWAP = 1450;
    const ease = (u) => u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2;

    function measure(i) {
      const g = SIGNIN_GLIMPSES[i];
      ctx.font = FONT;
      const tw = ctx.measureText(g.t).width;
      return { text: g.t, color: g.live ? '201,168,76' : '208,201,184',
        x0: W / 2 - tw / 2, x1: W / 2 + tw / 2 };
    }
    let cur = { text: '', color: '208,201,184', x0: W / 2, x1: W / 2 };
    let nextIdx = 0, nxt = measure(0);

    let ps = [];
    function spawn(ex, color) {
      for (let k = 0; k < 7; k++) {
        ps.push({ x: ex + (Math.random() - 0.5) * 4, y: MY + (Math.random() - 0.5) * 21,
          vx: 0.25 + Math.random() * 0.8, vy: (Math.random() - 0.5) * 0.6,
          life: 0, max: 420 + Math.random() * 320, color });
      }
    }
    function drawText(obj, clipL, clipR) {
      if (!obj.text || clipR <= clipL) return;
      ctx.save();
      ctx.beginPath(); ctx.rect(clipL, 0, clipR - clipL, H); ctx.clip();
      ctx.font = FONT; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.shadowColor = `rgba(${obj.color},0.5)`;
      ctx.shadowBlur = 7;
      ctx.fillStyle = `rgba(${obj.color},1)`;
      ctx.fillText(obj.text, W / 2, MY);
      ctx.shadowBlur = 0;
      ctx.fillText(obj.text, W / 2, MY);
      ctx.restore();
    }

    let raf, last = performance.now();
    function frame(now) {
      const dt = now - t0, fdt = Math.min(now - last, 40); last = now;
      ctx.clearRect(0, 0, W, H);
      const pad = 10;

      if (mode === 'swap') {
        const e = ease(Math.min(dt / SWAP, 1));
        const edge = -pad + (W + pad * 2) * e;
        // new line revealed to the LEFT of the edge, old line still shown to the RIGHT
        drawText(nxt, 0, edge);
        drawText(cur, edge, W);
        const lo = Math.min(cur.x0, nxt.x0) - 2, hi = Math.max(cur.x1, nxt.x1) + 2;
        if (edge > lo && edge < hi) spawn(edge, nxt.color);
        if (dt >= SWAP) { cur = nxt; mode = 'hold'; t0 = now; }
      } else {
        drawText(cur, 0, W);
        if (dt >= HOLD) { nextIdx = (nextIdx + 1) % SIGNIN_GLIMPSES.length; nxt = measure(nextIdx); mode = 'swap'; t0 = now; }
      }

      // edge particles
      for (let i = ps.length - 1; i >= 0; i--) {
        const p = ps[i];
        p.life += fdt;
        const t = p.life / p.max;
        if (t >= 1) { ps.splice(i, 1); continue; }
        p.x += p.vx * (fdt / 16); p.y += p.vy * (fdt / 16);
        ctx.fillStyle = `rgba(${p.color},${(1 - t).toFixed(3)})`;
        ctx.fillRect(p.x, p.y, 1.5, 1.5);
      }
      raf = requestAnimationFrame(frame);
    }
    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, []);
  return <canvas ref={ref} style={{ marginTop: 12, display: 'block' }}/>;
}

function SignInScreen({ onSignIn }) {
  const [open, setOpen] = uS(false);
  const [leaving, setLeaving] = uS(false);
  const dragStart = uR(null);

  const onDown = (e) => { dragStart.current = e.clientY; };
  const onMove = (e) => {
    if (dragStart.current == null) return;
    if (dragStart.current - e.clientY > 44) { setOpen(true); dragStart.current = null; }
  };
  const onUp = () => { dragStart.current = null; };

  const doSignIn = () => {
    if (leaving) return;
    setLeaving(true);
    setTimeout(() => onSignIn(), 560);
  };

  return (
    <div style={{ height: '100%', background: T.bg, position: 'relative', overflow: 'hidden' }}>
      <style>{`
        @keyframes mrtLinePulse { 0%,100% { opacity: .35; transform: scaleX(.65); } 50% { opacity: 1; transform: scaleX(1); } }
        @keyframes mrtChevFloat { 0%,100% { transform: translateY(2px); opacity: .45; } 50% { transform: translateY(-3px); opacity: 1; } }
        @keyframes mrtSignOut { from { opacity: 1; transform: scale(1); } to { opacity: 0; transform: scale(1.07); } }
        @keyframes mrtBloom { 0% { opacity: 0; transform: translate(-50%,-50%) scale(0.2); } 35% { opacity: 0.85; } 100% { opacity: 0; transform: translate(-50%,-50%) scale(4.2); } }
      `}</style>

      {/* Everything that fades/zooms out on sign-in */}
      <div style={{ position: 'absolute', inset: 0,
        animation: leaving ? 'mrtSignOut 0.6s cubic-bezier(0.4,0,0.2,1) forwards' : 'none' }}>
        {/* Soft gold wash from the top */}
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 380, background: `radial-gradient(140% 100% at 50% -20%, ${T.goldGlow3} 0%, rgba(0,0,0,0) 65%)`, pointerEvents: 'none' }}/>

      {/* Centered brand */}
      <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '0 32px' }}>
        <div style={{ marginBottom: 28 }}><HexLogo size={62}/></div>
        <Wordmark size={28}/>
        <ParticleLine/>
      </div>

      {/* Swipe-up affordance */}
      <div
        onPointerDown={onDown} onPointerMove={onMove} onPointerUp={onUp}
        onClick={() => setOpen(true)}
        style={{ position: 'absolute', left: 0, right: 0, bottom: 0, height: 168, cursor: 'pointer',
          display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'flex-end',
          paddingBottom: 30, gap: 14, touchAction: 'none',
          opacity: open ? 0 : 1, transition: 'opacity 0.3s ease', pointerEvents: open ? 'none' : 'auto' }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2 }}>
          {[0, 1].map((i) => (
            <svg key={i} width="20" height="11" viewBox="0 0 20 11"
              style={{ animation: `mrtChevFloat 1.6s ease-in-out ${i * 0.18}s infinite` }}>
              <path d="M2 8L10 2.5L18 8" fill="none" stroke={T.gold} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          ))}
        </div>
        <div style={{ width: 132, height: 3, borderRadius: 2, background: `linear-gradient(90deg, rgba(201,168,76,0) 0%, ${T.gold} 50%, rgba(201,168,76,0) 100%)`,
          animation: 'mrtLinePulse 1.8s ease-in-out infinite' }}/>
        <div style={{ fontSize: 12.5, color: T.textSec, fontWeight: 500, letterSpacing: 0.3 }}>Swipe up to sign in</div>
      </div>

      {/* Scrim */}
      <div onClick={() => setOpen(false)}
        style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.5)',
          opacity: open ? 1 : 0, pointerEvents: open ? 'auto' : 'none', transition: 'opacity 0.35s ease' }}/>

        {/* Login sheet */}
        <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0,
          background: T.bgSecondary, borderTopLeftRadius: T.radiusSheet, borderTopRightRadius: T.radiusSheet,
          borderTop: `0.5px solid ${T.border}`, boxShadow: '0 -20px 50px rgba(0,0,0,0.6)',
          padding: '14px 24px 34px', transform: open ? 'translateY(0)' : 'translateY(110%)',
          transition: 'transform 0.42s cubic-bezier(0.32, 0.72, 0, 1)' }}>
          <div style={{ width: 38, height: 4, borderRadius: 2, background: T.elevated, margin: '0 auto 22px' }}/>
          <div style={{ fontSize: 21, fontWeight: 600, color: T.text, letterSpacing: -0.3, textAlign: 'center', marginBottom: 4 }}>Welcome</div>
          <div style={{ fontSize: 13.5, color: T.textSec, textAlign: 'center', marginBottom: 26 }}>Continue with your Apple Account.</div>
          <button onClick={doSignIn}
            style={{ width: '100%', height: 54, borderRadius: 14, border: 'none', cursor: 'pointer',
              background: '#FFFFFF', color: '#000000', fontFamily: T.font, fontSize: 16, fontWeight: 600,
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 9 }}>
            <SFIcon name="apple.logo" size={19} color="#000000"/> Sign in with Apple
          </button>
          <div style={{ fontSize: 11, color: T.textMuted, textAlign: 'center', marginTop: 18, lineHeight: 1.5 }}>
            By continuing, you agree to our Terms and Privacy.
          </div>
        </div>
      </div>

      {/* Gold bloom on sign-in */}
      {leaving && (
        <div style={{ position: 'absolute', top: '50%', left: '50%', width: 260, height: 260, borderRadius: '50%',
          background: `radial-gradient(circle, ${T.gold} 0%, rgba(201,168,76,0.5) 35%, rgba(201,168,76,0) 70%)`,
          pointerEvents: 'none', animation: 'mrtBloom 0.62s cubic-bezier(0.4,0,0.2,1) forwards' }}/>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 2 · Empty State
// ─────────────────────────────────────────────────────────────
function EmptyScreen({ onAdd, onInvite }) {
  const paths = [
    { key: 'add', primary: true, icon: 'car.fill', title: 'Add your Tesla', sub: 'Link your vehicle to drive, track, and share it.', onClick: onAdd },
    { key: 'invite', primary: false, icon: 'person.fill', title: 'Join with an invite code', sub: 'Ride in a Tesla someone has shared with you.', onClick: onInvite },
  ];
  return (
    <div style={{ height: '100%', background: T.bg, position: 'relative', overflow: 'hidden' }}>
      {/* Soft gold wash from the top — matches the Sign In screen / brand mark */}
      <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 380, background: `radial-gradient(140% 100% at 50% -20%, ${T.goldGlow3} 0%, rgba(0,0,0,0) 65%)`, pointerEvents: 'none' }}/>
      <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '0 28px' }}>
        {/* Brand mark, echoing the Sign In screen */}
        <div style={{ marginBottom: 30 }}><HexLogo size={58} glow/></div>
        <div style={{ fontSize: 24, fontWeight: 600, color: T.text, letterSpacing: -0.5, marginBottom: 9 }}>Welcome to MyRoboTaxi</div>
        <div style={{ fontSize: 14, color: T.textSec, fontWeight: 400, textAlign: 'center', maxWidth: 268, lineHeight: 1.5, marginBottom: 34 }}>
          How would you like to get started?
        </div>
        <div style={{ width: '100%', display: 'flex', flexDirection: 'column', gap: 13 }}>
          {paths.map((p) => (
            <button key={p.key} onClick={p.onClick} style={{
              position: 'relative', display: 'flex', alignItems: 'center', gap: 15, width: '100%', textAlign: 'left',
              padding: '17px 18px', borderRadius: 20, cursor: 'pointer', WebkitTapHighlightColor: 'transparent',
              background: p.primary ? `linear-gradient(150deg, ${T.gold}1c, ${T.gold}0a)` : 'rgba(255,255,255,0.035)',
              border: p.primary ? `1px solid ${T.gold}66` : `1px solid ${T.gold}2e`,
            }}>
              <div style={{ width: 46, height: 46, borderRadius: 14, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
                background: p.primary ? `${T.gold}26` : 'rgba(255,255,255,0.05)', border: `0.5px solid ${p.primary ? `${T.gold}55` : T.border}` }}>
                <SFIcon name={p.icon} size={22} color={p.primary ? T.gold : T.textSec}/>
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 16, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>{p.title}</div>
                <div style={{ fontSize: 12.5, color: T.textSec, lineHeight: 1.4, marginTop: 3 }}>{p.sub}</div>
              </div>
              <SFIcon name="chevron.right" size={14} color={p.primary ? T.gold : T.textMuted}/>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 3 · Live Map / Home — the primary screen.
// ─────────────────────────────────────────────────────────────
function MapHeader({ vehicleIdx, onSwitch, vehicleCount }) {
  const [open, setOpen] = uS(false);
  const v = VEHICLES[vehicleIdx];
  const single = vehicleCount <= 1;
  return (
    <div style={{ position: 'absolute', top: 60, left: 0, right: 0, zIndex: 30, display: 'flex', flexDirection: 'column', alignItems: 'center', pointerEvents: 'none' }}>
      {/* Current-vehicle chip — tap to switch */}
      <button onClick={() => !single && setOpen(o => !o)} style={{
        pointerEvents: 'auto', display: 'inline-flex', alignItems: 'center', gap: 9,
        height: 40, padding: '0 8px 0 14px', borderRadius: 20, cursor: single ? 'default' : 'pointer',
        background: 'rgba(20,20,24,0.72)', backdropFilter: 'blur(18px)', WebkitBackdropFilter: 'blur(18px)',
        border: `0.5px solid ${open ? `${T.gold}77` : 'rgba(255,255,255,0.14)'}`,
        boxShadow: '0 6px 20px rgba(0,0,0,0.4)', WebkitTapHighlightColor: 'transparent', transition: 'border-color .2s' }}>
        <SFIcon name="car.fill" size={16} color={T.gold}/>
        <span style={{ fontFamily: T.font, fontSize: 15, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>{v.name}</span>
        {!single && (
          <span style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', width: 24, height: 24, borderRadius: 12, background: 'rgba(255,255,255,0.08)', transform: open ? 'rotate(180deg)' : 'none', transition: 'transform .25s ease' }}>
            <SFIcon name="chevron.down" size={12} color={T.textSec}/>
          </span>
        )}
      </button>

      {/* Picker menu */}
      {open && !single && (
        <>
          <div onClick={() => setOpen(false)} style={{ position: 'fixed', inset: 0, zIndex: -1, pointerEvents: 'auto' }}/>
          <div style={{ pointerEvents: 'auto', marginTop: 8, width: 250, borderRadius: 16, overflow: 'hidden',
            background: 'rgba(24,24,28,0.92)', backdropFilter: 'blur(24px)', WebkitBackdropFilter: 'blur(24px)',
            border: '0.5px solid rgba(255,255,255,0.14)', boxShadow: '0 16px 44px rgba(0,0,0,0.55)',
            animation: 'mrt-fade-up .18s ease-out both' }}>
            {VEHICLES.map((veh, i) => {
              const on = i === vehicleIdx;
              return (
                <button key={veh.id} onClick={() => { onSwitch(i); setOpen(false); }} style={{
                  display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left', cursor: 'pointer',
                  padding: '13px 15px', background: on ? `${T.gold}14` : 'transparent', border: 'none',
                  borderTop: i ? '0.5px solid rgba(255,255,255,0.07)' : 'none', WebkitTapHighlightColor: 'transparent' }}>
                  <div style={{ width: 34, height: 34, borderRadius: 10, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
                    background: on ? `${T.gold}22` : 'rgba(255,255,255,0.06)' }}>
                    <SFIcon name="car.fill" size={17} color={on ? T.gold : T.textSec}/>
                  </div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontSize: 14.5, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>{veh.name}</div>
                    <div style={{ fontSize: 11.5, color: T.textMuted, marginTop: 1 }}>{veh.plate}</div>
                  </div>
                  {on && <SFIcon name="checkmark" size={15} color={T.gold} weight={2.4}/>}
                </button>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}

function FloatingMapButton({ icon, onClick, bottom = 280, right = 16, hidden = false }) {
  const S = useSurfaces();
  return (
    <button onClick={onClick} style={{
      position: 'absolute', bottom, right, width: 44, height: 44, borderRadius: 22,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      cursor: 'pointer', zIndex: 25,
      opacity: hidden ? 0 : 1,
      transform: hidden ? 'scale(0.9)' : 'scale(1)',
      pointerEvents: hidden ? 'none' : 'auto',
      transition: 'opacity .22s ease, transform .22s ease',
      ...S.floatBtn,
    }}>{icon}</button>
  );
}

function HomeScreen({ vehicleIdx, setVehicleIdx, sheet, setSheet, driving, progress, battery, speed, parkedStyle = 'floating', nav, setNav, mapHeight }) {
  const v = VEHICLES[vehicleIdx];
  const route = uM(() => buildSampleRoute(), []);
  const totalLen = 156; // approx miles for sample route
  const eta = Math.max(1, Math.round((1 - progress) * 87));
  // Vehicle position along route
  const vehiclePos = uM(() => {
    const segs = [];
    for (let i = 1; i < route.length; i++) {
      const dx = route[i][0] - route[i - 1][0], dy = route[i][1] - route[i - 1][1];
      segs.push(Math.sqrt(dx * dx + dy * dy));
    }
    const total = segs.reduce((a, b) => a + b, 0);
    let acc = 0, target = total * progress;
    for (let i = 0; i < segs.length; i++) {
      if (acc + segs[i] >= target) {
        const t = (target - acc) / segs[i];
        const x = route[i][0] + (route[i + 1][0] - route[i][0]) * t;
        const y = route[i][1] + (route[i + 1][1] - route[i][1]) * t;
        const dx = route[i + 1][0] - route[i][0], dy = route[i + 1][1] - route[i][1];
        const heading = Math.atan2(dx, -dy) * 180 / Math.PI;
        return { x, y, heading };
      }
      acc += segs[i];
    }
    return { x: route[route.length - 1][0], y: route[route.length - 1][1], heading: 0 };
  }, [progress, route]);

  const status = driving ? 'driving' : 'parked';
  // Parked styles: floating (map-first, ~110 peek), pill (~60 peek), sheet (orig.)
  // Driving still uses the sheet.
  const peekH = driving ? 280 : parkedStyle === 'pill' ? 150 : parkedStyle === 'floating' ? 210 : 280;
  const halfH = Math.round(mapHeight * 0.58);

  return (
    <div style={{ position: 'absolute', inset: 0, background: '#070707', overflow: 'hidden' }}>
      <MapBackground width={402} height={mapHeight + 40} seed={42}/>
      {/* Route + markers */}
      <svg width={402} height={mapHeight + 40} viewBox={`0 0 402 ${mapHeight + 40}`} style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
        {driving && (
          <>
            <RouteLine path={route} progress={progress}/>
            <EndpointDot x={route[0][0]} y={route[0][1]} color={T.driving} size={10}/>
            <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={11}/>
          </>
        )}
      </svg>
      {/* Vehicle marker */}
      <div style={{ position: 'absolute', left: driving ? vehiclePos.x : 200, top: driving ? vehiclePos.y : 320, transition: 'left .8s linear, top .8s linear' }}>
        <VehicleMarker heading={driving ? vehiclePos.heading : 0} label={v.name}/>
      </div>
      <CompassLabels/>
      <MapHeader vehicleIdx={vehicleIdx} onSwitch={setVehicleIdx} vehicleCount={VEHICLES.length}/>

      {driving && (
        <FloatingMapButton bottom={peekH + 80} hidden={sheet === 'half'} icon={
          <SFIcon name="locate" size={20} color={T.gold}/>
        } onClick={() => {}}/>
      )}

      <BottomSheet peekH={peekH} halfH={halfH} height={sheet} onChange={setSheet} navHeight={0}>
        {driving ? <DrivingSheetContent v={v} progress={progress} battery={battery} speed={speed} eta={eta} expanded={sheet === 'half'}/> :
          <ParkedSheetContent v={v} battery={battery} expanded={sheet === 'half'} style={parkedStyle}/>}
      </BottomSheet>

      <BottomNav current={nav} onChange={setNav} hidden={sheet === 'half'}/>
    </div>
  );
}

function DrivingSheetContent({ v, progress, battery, speed, eta, expanded }) {
  const destName = 'Duarte\'s Tavern';
  const destCity = 'Pescadero';
  const arrival = uM(() => {
    const d = new Date(Date.now() + eta * 60000);
    let h = d.getHours(); const m = d.getMinutes();
    const ap = h >= 12 ? 'PM' : 'AM'; h = h % 12 || 12;
    return `${h}:${String(m).padStart(2, '0')} ${ap}`;
  }, [eta]); // eslint-disable-line
  const rangeMi = Math.round((battery / 100) * 272);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 22 }}>
      {/* Hero — destination and arrival are the focus */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
            <span style={{ width: 7, height: 7, borderRadius: 4, background: T.driving, boxShadow: `0 0 7px ${T.driving}aa` }}/>
            <span style={{ fontSize: 13, color: T.text, fontWeight: 600, letterSpacing: 0.1 }}>Driving</span>
            <span style={{ fontSize: 13, color: T.textMuted, fontWeight: 400 }}>· {v.name}</span>
          </div>
          {/* Range — top-right, aligned with status */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <MiniBattery pct={battery}/>
            <span style={{ fontFamily: T.fontNum, fontSize: 13, color: T.textSec, fontWeight: 500, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.1 }}>
              {rangeMi}<span style={{ color: T.textMuted, fontWeight: 400, marginLeft: 2 }}>mi</span>
            </span>
          </div>
        </div>
        <div>
          <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', gap: 12 }}>
            <div style={{ fontSize: 28, fontWeight: 600, color: T.text, letterSpacing: -0.8, lineHeight: 1.05, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{destName}</div>
            {/* Live speed — the one constantly-updating figure, kept at the top */}
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 3, flexShrink: 0 }}>
              <span style={{ fontFamily: T.fontNum, fontSize: 27, fontWeight: 600, color: T.text, letterSpacing: -0.8, lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>{speed}</span>
              <span style={{ fontSize: 12, color: T.textMuted, fontWeight: 500 }}>mph</span>
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginTop: 10 }}>
            <span style={{ fontSize: 15, color: T.textSec, fontWeight: 400, letterSpacing: -0.2 }}>
              Arriving in <span style={{ color: T.text, fontWeight: 600 }}>{eta} min</span>
            </span>
            <span style={{ fontSize: 14, color: T.textMuted, fontWeight: 400, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.1 }}>ETA {arrival}</span>
          </div>
        </div>
      </div>

      {/* Journey line */}
      <TripProgressBar progress={progress} origin="Home" dest={destCity} compact/>

      {expanded && (
        <div className="mrt-reveal" style={{ display: 'flex', flexDirection: 'column', gap: 0 }}>
          <Divider pad={8}/>
          <Label style={{ marginBottom: 8 }}>Route</Label>
          <RouteLeg color={T.driving} title="Home" subtitle="221 Folsom St, San Francisco" first/>
          <RouteLeg color={T.gold} title="Pescadero · Duarte's Tavern" subtitle="202 Stage Rd, Pescadero" last/>
          <VehicleControls v={v} status="driving" battery={battery} speed={speed}/>
        </div>
      )}
    </div>
  );
}

function RouteLeg({ title, subtitle, color, first, mid, last, charging }) {
  return (
    <div style={{ display: 'flex', gap: 14, padding: '6px 0' }}>
      <div style={{ width: 18, display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
        {!first && <div style={{ width: 1, height: 6, background: T.border }}/>}
        {charging ?
          <div style={{ width: 16, height: 16, borderRadius: 8, background: T.charging, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <SFIcon name="bolt.fill" size={10} color="#1a1408"/>
          </div>
          : <div style={{ width: 10, height: 10, borderRadius: 5, background: color, boxShadow: `0 0 8px ${color}66` }}/>
        }
        {!last && <div style={{ flex: 1, width: 1, background: T.border, minHeight: 14 }}/>}
      </div>
      <div style={{ flex: 1, paddingBottom: 6 }}>
        <div style={{ fontSize: 14, color: T.text, fontWeight: 500 }}>{title}</div>
        <div style={{ fontSize: 12, color: T.textSec, marginTop: 2 }}>{subtitle}</div>
      </div>
    </div>
  );
}

function ParkedSheetContent({ v, battery, expanded, style = 'floating' }) {
  // Compact peek content — map is the focus
  let peekContent;
  if (style === 'pill') {
    // Single-line minimal
    peekContent = (
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '2px 0' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flex: 1, minWidth: 0 }}>
          <span style={{ width: 7, height: 7, borderRadius: 4, background: T.parked, boxShadow: `0 0 6px ${T.parked}99` }}/>
          <span style={{ fontSize: 15, fontWeight: 600, color: T.text, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {v.name}
          </span>
          <span style={{ fontSize: 12, color: T.textSec, fontWeight: 400, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            · Embarcadero · 1h 42m
          </span>
        </div>
        <div style={{ fontFamily: T.fontNum, fontSize: 14, color: T.text, fontVariantNumeric: 'tabular-nums', fontWeight: 500 }}>
          {Math.round(battery)}<span style={{ color: T.textMuted, fontSize: 11, marginLeft: 1 }}>%</span>
        </div>
      </div>
    );
  } else if (style === 'floating') {
    // Two-line compact card — vehicle + battery, then location + duration
    peekContent = (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flex: 1, minWidth: 0 }}>
            <span style={{ fontSize: 18, fontWeight: 600, color: T.text, letterSpacing: -0.3 }}>{v.name}</span>
            <StatusBadge status="parked"/>
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 4 }}>
            <span style={{ fontFamily: T.fontNum, fontSize: 18, fontWeight: 400, color: T.text, fontVariantNumeric: 'tabular-nums', lineHeight: 1, letterSpacing: -0.3 }}>{Math.round(battery)}</span>
            <span style={{ fontSize: 11, color: T.textMuted }}>%</span>
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <BatteryBar pct={battery} style={{ flex: 1 }}/>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, fontSize: 12, marginTop: 2 }}>
          <span style={{ color: T.text, fontWeight: 400, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>Embarcadero Center · Lot B</span>
          <span style={{ color: T.textMuted, fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>1h 42m</span>
        </div>
      </div>
    );
  } else {
    // 'sheet' — original compact-ish peek
    peekContent = (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <div style={{ fontSize: 18, fontWeight: 600, color: T.text, letterSpacing: -0.3 }}>{v.name}</div>
            <StatusBadge status="parked"/>
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          <div style={{ fontSize: 14, color: T.text, fontWeight: 400 }}>Embarcadero Center · Lot B</div>
          <div style={{ fontSize: 12, color: T.textSec }}>Parked 1h 42m ago</div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <BatteryBar pct={battery}/>
          <div style={{ fontFamily: T.fontNum, fontSize: 13, color: T.text, fontVariantNumeric: 'tabular-nums', fontWeight: 500, minWidth: 38, textAlign: 'right' }}>{Math.round(battery)}%</div>
        </div>
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      {peekContent}

      {expanded && (
        <div className="mrt-reveal" style={{ display: 'flex', flexDirection: 'column' }}>
          <VehicleControls v={v} status="parked" battery={battery}/>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 4 · Drive History
// ─────────────────────────────────────────────────────────────
function DrivesScreen({ nav, setNav, onOpenDrive, driving, upcoming = [], onCancelUpcoming }) {
  const S = useSurfaces();
  const [tab, setTab] = uS('history');   // history | upcoming
  const [sort, setSort] = uS('date');
  const [confirmCancel, setConfirmCancel] = uS(null); // reserved ride pending cancel confirmation
  const DAY_ORDER = ['Today', 'Tomorrow', 'Thu', 'Fri', 'Sat', 'Sun', 'Mon'];
  const toMin = (t) => { const m = (t || '').match(/(\d+):(\d+)\s*(AM|PM)/i); if (!m) return 0; let h = parseInt(m[1], 10) % 12; if (/pm/i.test(m[3])) h += 12; return h * 60 + parseInt(m[2], 10); };
  const upSorted = uM(() => [...upcoming].sort((a, b) => {
    const da = DAY_ORDER.indexOf(a.schedule.day), db = DAY_ORDER.indexOf(b.schedule.day);
    return da !== db ? da - db : toMin(a.schedule.time) - toMin(b.schedule.time);
  }), [upcoming]);
  const sortedDrives = uM(() => {
    const arr = [...DRIVES];
    if (sort === 'distance') arr.sort((a, b) => b.miles - a.miles);
    else if (sort === 'duration') arr.sort((a, b) => b.mins - a.mins);
    return arr;
  }, [sort]);
  const grouped = uM(() => {
    if (sort !== 'date') return { 'All drives': sortedDrives };
    const out = {};
    sortedDrives.forEach(d => { (out[d.date] = out[d.date] || []).push(d); });
    return out;
  }, [sortedDrives, sort]);
  const groupLabel = (k) => k === 'today' ? 'Today' : k === 'yesterday' ? 'Yesterday' : k;
  return (
    <div style={{ position: 'absolute', inset: 0, background: T.bg, display: 'flex', flexDirection: 'column' }}>
      {/* Header */}
      <div style={{ padding: '74px 24px 16px' }}>
        <div style={{ fontSize: 28, fontWeight: 600, color: T.text, letterSpacing: -0.6, marginBottom: 4 }}>Drives</div>
        <div style={{ fontSize: 13, color: T.textSec, fontWeight: 400 }}>{VEHICLES[0].name} · 42,184 mi total</div>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 104 }}>
        {/* Segmented control — separates past drives from upcoming reservations */}
        <div style={{ display: 'flex', gap: 3, margin: '0 24px 18px', padding: 3, borderRadius: 12, background: 'rgba(255,255,255,0.05)' }}>
          {[['history', 'History'], ['upcoming', `Upcoming${upSorted.length ? ` · ${upSorted.length}` : ''}`]].map(([k, label]) => (
            <button key={k} onClick={() => setTab(k)} style={{
              flex: 1, padding: '8px 6px', borderRadius: 9, border: 'none', cursor: 'pointer',
              fontFamily: T.font, fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
              background: tab === k ? T.gold : 'transparent', color: tab === k ? '#1a1408' : T.textSec,
              transition: 'background .18s, color .18s', WebkitTapHighlightColor: 'transparent',
            }}>{label}</button>
          ))}
        </div>

        {tab === 'history' ? (
          <>
            {driving && (
              <div onClick={() => setNav('home')} style={{
                margin: '0 24px 16px', padding: '15px 16px', borderRadius: 16, cursor: 'pointer',
                display: 'flex', alignItems: 'center', gap: 12,
                background: 'linear-gradient(122deg, rgba(48,209,88,0.14) 0%, rgba(48,209,88,0.04) 42%, rgba(255,255,255,0.018) 100%)',
                border: '0.5px solid rgba(48,209,88,0.34)',
                boxShadow: '0 1px 0 rgba(255,255,255,0.04) inset, 0 6px 20px rgba(0,0,0,0.28)',
                WebkitTapHighlightColor: 'transparent',
              }}>
                <PulseDot color={T.driving}/>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
                    <span style={{ fontSize: 15, fontWeight: 600, color: '#EAF6EC', letterSpacing: -0.2, flex: 1, minWidth: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                      Home <span style={{ color: T.driving, fontWeight: 400 }}>→</span> Pescadero
                    </span>
                    <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1, color: T.driving, textTransform: 'uppercase', flexShrink: 0 }}>En route</span>
                  </div>
                  <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 5, fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums' }}>
                    <span style={{ color: T.driving, fontWeight: 600 }}>51 min</span> remaining · 28.4 mi
                  </div>
                </div>
                <SFIcon name="chevron.right" size={15} color="rgba(48,209,88,0.6)"/>
              </div>
            )}
            {/* Sort menu */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '0 24px 14px' }}>
              <span style={{ fontSize: 12, color: T.textMuted, fontWeight: 500 }}>Sort by</span>
              <div style={{ display: 'flex', gap: 6 }}>
                {['date', 'distance', 'duration'].map(k => (
                  <button key={k} onClick={() => setSort(k)} style={{
                    padding: '5px 11px', borderRadius: 999, cursor: 'pointer',
                    fontFamily: T.font, fontSize: 12, fontWeight: 600, letterSpacing: -0.1, textTransform: 'capitalize',
                    border: sort === k ? '0.5px solid transparent' : `0.5px solid ${T.border}`,
                    background: sort === k ? `${T.gold}22` : 'transparent',
                    color: sort === k ? T.gold : T.textSec, WebkitTapHighlightColor: 'transparent',
                  }}>{k}</button>
                ))}
              </div>
            </div>
            {Object.entries(grouped).map(([k, items]) => (
              <div key={k} style={{ marginBottom: 16 }}>
                <div style={{ padding: '0 24px 10px' }}><Label>{groupLabel(k)}</Label></div>
                {items.map((d) => <DriveRow key={d.id} d={d} onClick={() => onOpenDrive(d.id)}/>)}
              </div>
            ))}
          </>
        ) : (
          upSorted.length > 0 ? (
            <div>
              {upSorted.map((u) => <UpcomingRow key={u.id} u={u} onCancel={(ride) => setConfirmCancel(ride)}/>)}
            </div>
          ) : (
            <div style={{ textAlign: 'center', padding: '48px 32px', color: T.textMuted }}>
              <div style={{ width: 52, height: 52, borderRadius: 26, background: 'rgba(255,255,255,0.04)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
                <SFIcon name="calendar" size={22} color={T.textMuted}/>
              </div>
              <div style={{ fontSize: 14, color: T.textSec, fontWeight: 500 }}>No upcoming rides</div>
              <div style={{ fontSize: 12.5, color: T.textMuted, marginTop: 4, lineHeight: 1.45 }}>Scheduled rides you accept will appear here.</div>
            </div>
          )
        )}
      </div>

      {/* Cancel reserved-ride confirmation */}
      {confirmCancel && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 70, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 28 }}>
          <div onClick={() => setConfirmCancel(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .2s ease-out both' }}/>
          <div style={{ position: 'relative', width: '100%', maxWidth: 300, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, boxShadow: '0 20px 60px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .28s cubic-bezier(.32,.72,0,1) both', textAlign: 'center' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="calendar" size={20} color="#FF6B6B"/>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Cancel this reservation?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>
              This cancels <span style={{ color: T.text, fontWeight: 600 }}>{confirmCancel.dest?.label}</span> on {confirmCancel.schedule.day} {confirmCancel.schedule.time} for {confirmCancel.rider}.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <button onClick={() => { onCancelUpcoming && onCancelUpcoming(confirmCancel.id); setConfirmCancel(null); }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: 'none', cursor: 'pointer',
                background: 'rgba(255,59,48,0.16)', color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                WebkitTapHighlightColor: 'transparent',
              }}>Cancel reservation</button>
              <button onClick={() => setConfirmCancel(null)} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: T.text, fontFamily: T.font, fontSize: 15, fontWeight: 500,
                WebkitTapHighlightColor: 'transparent',
              }}>Keep it</button>
            </div>
          </div>
        </div>
      )}

      <BottomNav current={nav} onChange={setNav}/>
    </div>
  );
}

function UpcomingRow({ u, onCancel }) {
  return (
    <div style={{
      margin: '0 24px 11px', padding: '14px 16px', borderRadius: 16, display: 'flex', alignItems: 'center', gap: 13,
      background: 'linear-gradient(122deg, rgba(201,168,76,0.10) 0%, rgba(201,168,76,0.03) 34%, rgba(255,255,255,0.018) 100%)',
      border: '0.5px solid rgba(201,168,76,0.20)',
      boxShadow: '0 1px 0 rgba(255,255,255,0.04) inset, 0 6px 20px rgba(0,0,0,0.28)',
    }}>
      <div style={{ width: 38, height: 38, borderRadius: 11, background: 'rgba(201,168,76,0.16)', border: '0.5px solid rgba(201,168,76,0.28)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
        <SFIcon name="calendar" size={16} color={T.gold}/>
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 600, color: '#F4EFE2', letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{u.dest?.label}</div>
        <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 4, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          <span style={{ color: T.gold, fontWeight: 600 }}>{u.schedule.day} {u.schedule.time}</span> · For {u.rider}
        </div>
      </div>
      {onCancel && (
        <button onClick={() => onCancel(u)} aria-label="Cancel reserved ride" style={{ width: 28, height: 28, borderRadius: 14, background: 'rgba(255,255,255,0.06)', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <SFIcon name="xmark" size={10} color={T.textMuted} weight={2}/>
        </button>
      )}
    </div>
  );
}

function DriveRow({ d, onClick }) {
  const fsd = ((d.fsd / d.miles) * 100).toFixed(0);
  return (
    <div onClick={onClick} style={{
      position: 'relative', margin: '0 24px 11px', padding: '15px 16px', borderRadius: 16, cursor: 'pointer', overflow: 'hidden',
      display: 'flex', alignItems: 'center', gap: 12,
      background: 'linear-gradient(122deg, rgba(201,168,76,0.10) 0%, rgba(201,168,76,0.03) 34%, rgba(255,255,255,0.018) 100%)',
      border: '0.5px solid rgba(201,168,76,0.20)',
      boxShadow: '0 1px 0 rgba(255,255,255,0.04) inset, 0 6px 20px rgba(0,0,0,0.28)',
      WebkitTapHighlightColor: 'transparent',
    }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
          <span style={{ fontSize: 15, fontWeight: 600, color: '#F4EFE2', letterSpacing: -0.2, flex: 1, minWidth: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {d.from} <span style={{ color: T.gold, fontWeight: 400 }}>→</span> {d.to}
          </span>
          <span style={{ fontFamily: T.fontNum, fontSize: 12, color: 'rgba(201,168,76,0.65)', fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>{d.start}</span>
        </div>
        <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 5, fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums' }}>
          {d.miles.toFixed(1)} mi · {d.mins} min · <span style={{ color: T.gold, fontWeight: 600 }}>{fsd}% FSD</span>
        </div>
      </div>
      <SFIcon name="chevron.right" size={15} color="rgba(201,168,76,0.55)"/>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 5 · Drive Summary
// ─────────────────────────────────────────────────────────────
// Hero route in the wide summary map's own 402×330 coordinate space —
// a city-to-waterfront diagonal that reads like a real drive.
const DS_HERO_ROUTE = [
  [40, 256], [70, 248], [98, 252], [126, 234], [150, 230], [174, 210],
  [196, 206], [220, 184], [244, 178], [268, 156], [294, 142], [320, 120], [350, 96]
];

// Add minutes to a "9:12 AM" style clock string → "9:41 AM".
function addClockMinutes(timeStr, mins) {
  const m = String(timeStr || '').match(/(\d+):(\d+)\s*(AM|PM)/i);
  if (!m) return timeStr;
  let h = (+m[1]) % 12; if (m[3].toUpperCase() === 'PM') h += 12;
  let total = (((h * 60 + (+m[2]) + (mins || 0)) % 1440) + 1440) % 1440;
  let hh = Math.floor(total / 60), mm = total % 60;
  const ap = hh >= 12 ? 'PM' : 'AM'; hh = hh % 12 || 12;
  return `${hh}:${String(mm).padStart(2, '0')} ${ap}`;
}

// Normalize any trip (owner DRIVE or shared ride) into the fields the
// summary needs. Shared rides are 100% autonomous robotaxi trips.
function normalizeDrive(base) {
  return {
    ...base,
    end: base.end || addClockMinutes(base.start, base.mins),
    fsd: base.fsd != null ? base.fsd : base.miles,
    chg: base.chg != null ? base.chg : -Math.max(2, Math.round(base.miles * 0.45)),
  };
}

function DriveSummaryScreen({ driveId, drive, onBack }) {
  const d = normalizeDrive(drive || DRIVES.find(x => x.id === driveId) || DRIVES[2]);
  const seedN = uM(() => String(d.id).split('').reduce((a, c) => a + c.charCodeAt(0), 0), [d.id]);

  // Deterministic speed trace (stable across renders, unique per drive).
  const speeds = uM(() => {
    let s = seedN + 7;
    const rnd = () => (s = (s * 9301 + 49297) % 233280) / 233280;
    return Array.from({ length: 60 }, (_, i) => {
      const t = i / 59;
      const ramp = Math.min(1, t * 5) * Math.min(1, (1 - t) * 5); // ease in/out at ends
      return 6 + ramp * (50 + 22 * Math.sin(t * 3.0 + 0.3) + 9 * Math.sin(t * 9.5) + rnd() * 8);
    });
  }, [seedN]);
  const maxS = Math.round(Math.max(...speeds));
  const avgS = Math.round(speeds.reduce((a, b) => a + b, 0) / speeds.length + 6);
  const fsdPct = Math.round((d.fsd / d.miles) * 100);
  const startPct = Math.min(97, 76 + (seedN % 18));
  const endPct = Math.max(6, startPct + d.chg);
  const dateLabel = d.date === 'today' ? 'Today' : d.date === 'yesterday' ? 'Yesterday' : d.date;

  // After a flawless 100% drive celebrates, ease the whole page into a warm
  // gold theme — the reward lingers so the drive feels truly special.
  const isFull = fsdPct >= 100;
  const reduceMotion = uM(() => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches, []);
  const [goldMode, setGoldMode] = uS(false);
  uE(() => {
    if (!isFull) { setGoldMode(false); return undefined; }
    const t = setTimeout(() => setGoldMode(true), reduceMotion ? 200 : 2700); // after the burst settles
    return () => clearTimeout(t);
  }, [isFull, reduceMotion]);

  return (
    <div style={{ position: 'absolute', inset: 0, background: T.bg, overflowY: isFull ? 'hidden' : 'auto', fontFamily: T.font }}>
      {/* Warm gold reward wash — eases in behind everything after the celebration */}
      <div style={{
        position: 'absolute', inset: 0, zIndex: 0, pointerEvents: 'none',
        background: 'radial-gradient(125% 62% at 50% 60%, rgba(201,168,76,0.22), rgba(201,168,76,0.08) 46%, transparent 76%), linear-gradient(180deg, transparent 32%, rgba(201,168,76,0.05) 55%, rgba(201,168,76,0.12) 100%)',
        opacity: goldMode ? 1 : 0,
        transition: reduceMotion ? 'none' : 'opacity 1.4s cubic-bezier(0.4,0,0.2,1)',
      }}/>
      {/* ── Map hero — the full route ────────────────────────── */}
      <div style={{ position: 'relative', zIndex: 1, height: 268, overflow: 'hidden' }}>
        <MapBackground width={402} height={268} seed={seedN + 21}/>
        <svg width="402" height="200" viewBox="18 78 366 204" preserveAspectRatio="xMidYMid meet" style={{ position: 'absolute', top: 50, left: 0 }}>
          <RouteLine path={DS_HERO_ROUTE} progress={1} width={4.5}/>
          <EndpointDot x={DS_HERO_ROUTE[0][0]} y={DS_HERO_ROUTE[0][1]} color={T.driving} size={13}/>
          <EndpointDot x={DS_HERO_ROUTE[DS_HERO_ROUTE.length - 1][0]} y={DS_HERO_ROUTE[DS_HERO_ROUTE.length - 1][1]} color={T.gold} size={13}/>
        </svg>

        {/* legibility scrims */}
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 100, background: 'linear-gradient(180deg, rgba(10,10,10,0.62), rgba(10,10,10,0))', pointerEvents: 'none' }}/>
        <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, height: 140, background: 'linear-gradient(180deg, rgba(10,10,10,0) 0%, rgba(10,10,10,0.7) 55%, #0A0A0A 100%)', pointerEvents: 'none' }}/>
        {/* gold reward tint over the map */}
        <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', mixBlendMode: 'soft-light', background: 'linear-gradient(180deg, rgba(201,168,76,0.5), rgba(201,168,76,0.85))', opacity: goldMode ? 1 : 0, transition: reduceMotion ? 'none' : 'opacity 1.4s cubic-bezier(0.4,0,0.2,1)' }}/>
        <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', background: 'radial-gradient(80% 60% at 50% 30%, rgba(201,168,76,0.18), transparent 70%)', opacity: goldMode ? 1 : 0, transition: reduceMotion ? 'none' : 'opacity 1.4s cubic-bezier(0.4,0,0.2,1)' }}/>

        {/* Floating nav — back + share */}
        <div style={{ position: 'absolute', top: 52, left: 16, right: 16, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <button onClick={onBack} style={{ width: 38, height: 38, borderRadius: 19, background: 'rgba(10,10,10,0.5)', backdropFilter: 'blur(12px)', WebkitBackdropFilter: 'blur(12px)', border: '0.5px solid rgba(255,255,255,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer' }}>
            <SFIcon name="chevron.left" size={21} color={T.text}/>
          </button>
          <button style={{ width: 38, height: 38, borderRadius: 19, background: 'rgba(10,10,10,0.5)', backdropFilter: 'blur(12px)', WebkitBackdropFilter: 'blur(12px)', border: '0.5px solid rgba(255,255,255,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer' }}>
            <SFIcon name="square.and.arrow.up" size={18} color={T.gold}/>
          </button>
        </div>
      </div>

      {/* ── Celebratory header ───────────────────────────────── */}
      <div style={{ position: 'relative', zIndex: 1, padding: '8px 22px 0', marginTop: 0 }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: T.gold, letterSpacing: 1.4, textTransform: 'uppercase', marginBottom: 10 }}>{dateLabel}</div>
        <div style={{ fontSize: 22, fontWeight: 600, color: T.text, letterSpacing: -0.5, lineHeight: 1.15 }}>
          {d.from} <span style={{ color: T.gold, fontWeight: 400 }}>→</span> {d.to}
        </div>
        <div style={{ fontFamily: T.fontNum, fontSize: 13, color: T.textSec, marginTop: 9, fontVariantNumeric: 'tabular-nums' }}>{d.start} – {d.end}</div>
      </div>

      {/* ── Recap grid ───────────────────────────────────────── */}
      <div style={{ position: 'relative', zIndex: 1, padding: '20px 16px 0', display: 'flex', flexDirection: 'column', gap: 14 }}>
        {/* Distance + Duration */}
        <div style={{ display: 'flex', gap: 14 }}>
          <DSMetric label="Distance" value={d.miles.toFixed(1)} unit="mi"/>
          <DSMetric label="Duration" value={d.mins} unit="min"/>
        </div>

        {/* Full Self-Driving — the reward */}
        <div style={{ ...DS_TILE, padding: '20px 18px', display: 'flex', alignItems: 'center', gap: 18 }}>
          <DSRing pct={fsdPct} size={82}/>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 10.5, color: T.goldLight, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase' }}>Full Self-Driving</div>
            <div style={{ fontFamily: T.fontNum, fontSize: 30, fontWeight: 500, color: T.text, letterSpacing: -1.2, marginTop: 8, lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>
              <DSCountUp value={d.fsd} decimals={1}/><span style={{ fontSize: 15, color: T.textMuted, fontWeight: 500, marginLeft: 4 }}>mi</span>
            </div>
            <div style={{ fontSize: 11.5, color: T.textSec, marginTop: 6 }}>Driven autonomously</div>
          </div>
        </div>

        {/* Battery */}
        <div style={{ ...DS_TILE, padding: '17px 18px 18px' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 10.5, color: T.textMuted, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase' }}>Battery</span>
            <span style={{ fontFamily: T.fontNum, fontSize: 12, color: T.textSec, fontWeight: 500, fontVariantNumeric: 'tabular-nums' }}>{d.chg}% used</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 11, marginTop: 12 }}>
            <span style={{ fontFamily: T.fontNum, fontSize: 28, fontWeight: 500, color: T.text, letterSpacing: -1, fontVariantNumeric: 'tabular-nums' }}>{startPct}<span style={{ fontSize: 16, fontWeight: 500, marginLeft: 1 }}>%</span></span>
            <span style={{ fontSize: 16, color: T.textMuted, lineHeight: 1 }}>→</span>
            <span style={{ fontFamily: T.fontNum, fontSize: 28, fontWeight: 500, color: batteryColor(endPct), letterSpacing: -1, fontVariantNumeric: 'tabular-nums' }}>{endPct}<span style={{ fontSize: 16, fontWeight: 500, marginLeft: 1 }}>%</span></span>
          </div>
          <div style={{ position: 'relative', height: 10, marginTop: 20 }}>
            <div style={{ position: 'absolute', inset: 0, borderRadius: 5, background: 'rgba(255,255,255,0.06)', border: '0.5px solid rgba(255,255,255,0.08)', overflow: 'hidden' }}>
              {/* starting level — faint */}
              <div style={{ position: 'absolute', top: 0, bottom: 0, left: 0, width: `${startPct}%`, background: 'rgba(255,255,255,0.11)' }}/>
              {/* remaining charge at arrival */}
              <div style={{ position: 'absolute', top: 0, bottom: 0, left: 0, width: `${endPct}%`, background: `linear-gradient(90deg, ${batteryColor(endPct)}bb, ${batteryColor(endPct)})` }}/>
            </div>
            {/* start marker — pinpoints where the charge began */}
            <div style={{ position: 'absolute', top: -4, bottom: -4, left: `${startPct}%`, width: 2, marginLeft: -1, borderRadius: 1, background: T.gold, boxShadow: `0 0 6px ${T.goldGlow6}` }}/>
            <div style={{ position: 'absolute', top: -16, left: `${startPct}%`, transform: 'translateX(-50%)', fontSize: 9, fontWeight: 600, letterSpacing: 0.5, color: T.goldLight, textTransform: 'uppercase', whiteSpace: 'nowrap' }}>Start</div>
          </div>
        </div>

        {/* Speed */}
        <div style={{ display: 'flex', gap: 14 }}>
          <DSMetric label="Avg speed" value={avgS} unit="mph"/>
          <DSMetric label="Max speed" value={maxS} unit="mph" color={T.gold}/>
        </div>
      </div>

      <div style={{ height: 14 }}/>
    </div>
  );
}

// Shared card surface style for the summary.
const DS_CARD = { background: '#121212', border: `0.5px solid ${T.border}`, borderRadius: 18, overflow: 'hidden' };

function DSHeroStat({ value, unit, label, align = 'left' }) {
  return (
    <div style={{ flex: 1, padding: align === 'right' ? '16px 0 16px 22px' : '16px 22px 16px 2px', textAlign: align }}>
      <div style={{ fontFamily: T.fontNum, fontSize: 44, fontWeight: 300, color: T.text, letterSpacing: -1.6, lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>
        {value}<span style={{ fontSize: 17, color: T.textMuted, fontWeight: 400, marginLeft: 4, letterSpacing: 0 }}>{unit}</span>
      </div>
      <div style={{ fontSize: 10.5, color: T.textMuted, fontWeight: 500, letterSpacing: 1, textTransform: 'uppercase', marginTop: 9 }}>{label}</div>
    </div>
  );
}

// Section stat — big readable number + uppercase caption. Used for the
// FSD / Battery / Speed sections under the map.
function DSStat({ value, unit, label, color = T.text, align = 'left', glow = false }) {
  return (
    <div style={{ flex: 1, textAlign: align }}>
      <div style={{ fontFamily: T.fontNum, fontSize: 34, fontWeight: 300, color, letterSpacing: -1.2, lineHeight: 1, fontVariantNumeric: 'tabular-nums', textShadow: glow ? `0 0 22px ${T.goldGlow3}` : undefined }}>
        {value}<span style={{ fontSize: 15, color: T.textMuted, fontWeight: 400, marginLeft: 4, letterSpacing: 0 }}>{unit}</span>
      </div>
      <div style={{ fontSize: 10.5, color: T.textMuted, fontWeight: 500, letterSpacing: 1, textTransform: 'uppercase', marginTop: 10 }}>{label}</div>
    </div>
  );
}

// Contained metric tile — the building block of the recap grid.
const DS_TILE = {
  background: 'linear-gradient(158deg, rgba(255,255,255,0.06) 0%, rgba(255,255,255,0.025) 100%)',
  border: '0.5px solid rgba(255,255,255,0.09)',
  borderRadius: 18,
  boxShadow: '0 1px 0 rgba(255,255,255,0.05) inset, 0 8px 22px rgba(0,0,0,0.28)',
};

function DSMetric({ label, value, unit, color = T.text }) {
  return (
    <div style={{ flex: 1, minWidth: 0, ...DS_TILE, padding: '14px 16px 16px' }}>
      <div style={{ fontSize: 10.5, color: T.textMuted, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase' }}>{label}</div>
      <div style={{ fontFamily: T.fontNum, fontSize: 29, fontWeight: 500, color, letterSpacing: -1, marginTop: 10, lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>
        {value}<span style={{ fontSize: 14, color: T.textMuted, fontWeight: 500, marginLeft: 3 }}>{unit}</span>
      </div>
    </div>
  );
}

// Counts a number up from 0 on mount, easing out — matches the ring sweep.
function DSCountUp({ value, decimals = 0, duration = 1150, delay = 120 }) {
  const reduce = uM(() => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches, []);
  const [disp, setDisp] = uS(reduce ? value : 0);
  uE(() => {
    if (reduce) { setDisp(value); return undefined; }
    let raf; const t0 = performance.now() + delay;
    const ease = (t) => 1 - Math.pow(1 - t, 4); // easeOutQuart, close to the ring's curve
    const tick = (now) => {
      if (now < t0) { raf = requestAnimationFrame(tick); return; }
      const p = Math.min(1, (now - t0) / duration);
      setDisp(value * ease(p));
      if (p < 1) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [value, reduce]);
  return <>{disp.toFixed(decimals)}</>;
}

// Injects the celebration keyframes once (100% FSD burst + ring pop).
function ensureCelebrateStyle() {
  if (typeof document === 'undefined' || document.getElementById('ds-celebrate-style')) return;
  const el = document.createElement('style');
  el.id = 'ds-celebrate-style';
  el.textContent =
    // confetti: throw outward + fall under gravity, spinning, fading near the end
    '@keyframes dsConfetti{0%{opacity:0;transform:translate(-50%,-50%) scale(0.4) rotate(0deg)}' +
    '10%{opacity:1;transform:translate(calc(-50% + var(--mx)),calc(-50% + var(--my))) scale(1.1) rotate(calc(var(--rot)*0.4))}' +
    '70%{opacity:1}' +
    '100%{opacity:0;transform:translate(calc(-50% + var(--tx)),calc(-50% + var(--ty))) scale(0.85) rotate(var(--rot))}}' +
    '@keyframes dsPop{0%{transform:scale(1)}24%{transform:scale(1.16)}48%{transform:scale(0.96)}70%{transform:scale(1.05)}100%{transform:scale(1)}}' +
    '@keyframes dsGlow{0%{opacity:0;transform:scale(0.7)}30%{opacity:0.9}100%{opacity:0;transform:scale(1.9)}}' +
    '@keyframes dsRingFlash{0%{opacity:0;transform:scale(1)}25%{opacity:0.9}100%{opacity:0;transform:scale(1.45)}}';
  document.head.appendChild(el);
}

// Two-tone activity ring — strong gold arc for the autonomous portion,
// faint gold for the manual remainder. Fills from 0 on mount, Apple Watch–style.
// At 100% it celebrates with a big, rewarding gold confetti burst once it lands.
function DSRing({ pct, size = 92, stroke = 9 }) {
  const r = (size - stroke) / 2, c = 2 * Math.PI * r, cx = size / 2;
  const p = Math.min(100, pct) / 100;
  const target = c * (1 - p);
  const isFull = pct >= 100;
  const reduce = uM(() => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches, []);
  const [off, setOff] = uS(reduce ? target : c); // start empty, then fill
  const [celebrate, setCelebrate] = uS(false);
  const [burst, setBurst] = uS(false);
  uE(() => { ensureCelebrateStyle(); }, []);
  uE(() => {
    if (reduce) return undefined;
    const t = setTimeout(() => setOff(target), 120); // let the screen settle, then sweep
    return () => clearTimeout(t);
  }, [target, reduce]);
  uE(() => {
    if (reduce || !isFull) return undefined;
    const t = setTimeout(() => setCelebrate(true), 120 + 1150); // fire when the sweep completes
    return () => clearTimeout(t);
  }, [isFull, reduce]);
  // Mount confetti only for the burst window, then unmount so the off-screen
  // particles can't extend the page's scrollable area.
  uE(() => {
    if (!celebrate) return undefined;
    setBurst(true);
    const t = setTimeout(() => setBurst(false), 2500);
    return () => clearTimeout(t);
  }, [celebrate]);
  // Confetti — a generous burst that flies out and falls under gravity, spinning.
  const COLORS = [T.gold, T.goldLight, T.goldDark, '#FFFFFF', '#FFE9A8'];
  const particles = uM(() => {
    const N = 34;
    return Array.from({ length: N }, (_, i) => {
      const ang = (2 * Math.PI / N) * i + (Math.random() * 0.6 - 0.3);
      const dist = 64 + Math.random() * 70;
      const mx = Math.cos(ang) * dist * 0.55;
      const my = Math.sin(ang) * dist * 0.55 - 6;          // slight rise at the apex
      const tx = Math.cos(ang) * dist;
      const ty = Math.sin(ang) * dist + 46 + Math.random() * 60; // gravity pulls down
      const round = i % 3 === 0;
      return {
        mx: Math.round(mx), my: Math.round(my), tx: Math.round(tx), ty: Math.round(ty),
        rot: Math.round((Math.random() * 2 - 1) * 600),
        w: round ? 5 + Math.floor(Math.random() * 3) : 3 + Math.floor(Math.random() * 2),
        h: round ? 5 + Math.floor(Math.random() * 3) : 8 + Math.floor(Math.random() * 6),
        round, delay: Math.floor(Math.random() * 200),
        color: COLORS[i % COLORS.length],
        dur: 1500 + Math.floor(Math.random() * 600),
      };
    });
  }, []);
  return (
    <div style={{ position: 'relative', width: size, height: size, flexShrink: 0, animation: celebrate ? 'dsPop 0.8s cubic-bezier(0.34,1.56,0.64,1)' : 'none' }}>
      {/* celebratory glow halo */}
      {celebrate && (
        <div style={{ position: 'absolute', inset: -10, borderRadius: '50%', background: `radial-gradient(circle, ${T.goldGlow3}, transparent 62%)`, animation: 'dsGlow 1s ease-out forwards', pointerEvents: 'none' }}/>
      )}
      {/* expanding ring flash */}
      {celebrate && (
        <div style={{ position: 'absolute', inset: -2, borderRadius: '50%', border: `2px solid ${T.gold}`, animation: 'dsRingFlash 0.85s cubic-bezier(0.22,1,0.36,1) forwards', pointerEvents: 'none' }}/>
      )}
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ transform: 'rotate(-90deg)', display: 'block' }}>
        {/* manual remainder — light shade (full ring underneath) */}
        <circle cx={cx} cy={cx} r={r} stroke="rgba(201,168,76,0.22)" strokeWidth={stroke} fill="none"/>
        {/* autonomous portion — strong gold, animated sweep */}
        <circle cx={cx} cy={cx} r={r} stroke={T.gold} strokeWidth={stroke} fill="none" strokeDasharray={c} strokeDashoffset={off}
          style={{ transition: reduce ? 'none' : 'stroke-dashoffset 1.15s cubic-bezier(0.32,0.72,0,1)' }}/>
      </svg>
      {/* confetti burst */}
      {burst && particles.map((pt, i) => (
        <div key={i} style={{
          position: 'absolute', top: '50%', left: '50%', width: pt.w, height: pt.h,
          borderRadius: pt.round ? '50%' : 1, background: pt.color, zIndex: 3,
          ['--mx']: `${pt.mx}px`, ['--my']: `${pt.my}px`, ['--tx']: `${pt.tx}px`, ['--ty']: `${pt.ty}px`, ['--rot']: `${pt.rot}deg`,
          animation: `dsConfetti ${pt.dur}ms cubic-bezier(0.2,0.7,0.3,1) ${pt.delay}ms forwards`,
          pointerEvents: 'none',
        }}/>
      ))}
      <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <div style={{ fontFamily: T.fontNum, fontWeight: 600, color: isFull ? T.gold : T.text, letterSpacing: -0.5, fontVariantNumeric: 'tabular-nums', lineHeight: 1, transition: 'color 0.3s ease' }}>
          <span style={{ fontSize: 21 }}>{pct}</span>
          <span style={{ fontSize: 12, fontWeight: 500, marginLeft: 1 }}>%</span>
        </div>
      </div>
    </div>
  );
}

function DSInlineStat({ label, value, unit, gold }) {
  return (
    <div style={{ textAlign: 'right' }}>
      <span style={{ fontFamily: T.fontNum, fontSize: 19, fontWeight: 400, color: gold ? T.gold : T.text, letterSpacing: -0.4, fontVariantNumeric: 'tabular-nums' }}>
        {value}<span style={{ fontSize: 11, color: T.textMuted, marginLeft: 2 }}>{unit}</span>
      </span>
      <span style={{ fontSize: 9.5, color: T.textMuted, fontWeight: 500, letterSpacing: 1, textTransform: 'uppercase', marginLeft: 7 }}>{label}</span>
    </div>
  );
}

// Horizontal battery: green = charge remaining, amber = drained on this drive.
function DSBatteryTrack({ start, end }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
      <div style={{ flex: 1, position: 'relative', height: 26, borderRadius: 7, border: `1.5px solid ${T.elevated}`, padding: 3, boxSizing: 'border-box', background: '#0d0d0d' }}>
        <div style={{ position: 'relative', height: '100%', borderRadius: 4, overflow: 'hidden' }}>
          {/* remaining charge */}
          <div style={{ position: 'absolute', inset: 0, width: `${end}%`, background: `linear-gradient(90deg, ${batteryColor(end)}cc, ${batteryColor(end)})`, borderRadius: 4 }}/>
          {/* drained on this drive */}
          <div style={{ position: 'absolute', top: 0, bottom: 0, left: `${end}%`, width: `${start - end}%`, background: `repeating-linear-gradient(135deg, rgba(201,168,76,0.32) 0 6px, rgba(201,168,76,0.16) 6px 12px)` }}/>
          {/* start marker */}
          <div style={{ position: 'absolute', top: -3, bottom: -3, left: `${start}%`, width: 2, background: T.gold, boxShadow: `0 0 6px ${T.gold}` }}/>
        </div>
      </div>
      <div style={{ width: 3, height: 11, borderRadius: 2, background: T.elevated }}/>
    </div>
  );
}

function DSSparkline({ values, width, height, maxV }) {
  const max = Math.max(...values), min = Math.min(...values);
  const norm = (v) => height - ((v - min) / (max - min || 1)) * (height - 14) - 8;
  const pts = values.map((v, i) => [(i / (values.length - 1)) * width, norm(v)]);
  const line = pts.map((p, i) => `${i ? 'L' : 'M'} ${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(' ');
  const fill = line + ` L ${width} ${height} L 0 ${height} Z`;
  // peak marker
  let peakI = 0; values.forEach((v, i) => { if (v > values[peakI]) peakI = i; });
  return (
    <svg width="100%" height={height + 8} viewBox={`0 0 ${width} ${height + 8}`} preserveAspectRatio="none" style={{ display: 'block' }}>
      <defs>
        <linearGradient id="dsSpk" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={T.gold} stopOpacity="0.32"/>
          <stop offset="1" stopColor={T.gold} stopOpacity="0"/>
        </linearGradient>
      </defs>
      <path d={fill} fill="url(#dsSpk)"/>
      <path d={line} stroke={T.gold} strokeWidth="2" fill="none" strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" style={{ filter: `drop-shadow(0 0 4px ${T.goldGlow6})` }}/>
      <circle cx={pts[peakI][0]} cy={pts[peakI][1]} r="3" fill={T.gold} stroke="#0A0A0A" strokeWidth="1.5"/>
    </svg>
  );
}

// The polished card a rider shares to Messages / socials.
function DSShareCard({ d, dateLabel, fsdPct, seed }) {
  return (
    <div style={{ position: 'relative', borderRadius: 20, overflow: 'hidden', border: `0.5px solid rgba(201,168,76,0.3)`, boxShadow: `0 8px 40px rgba(0,0,0,0.5), 0 0 0 1px rgba(201,168,76,0.06)` }}>
      <div style={{ position: 'relative', height: 132, overflow: 'hidden' }}>
        <MapBackground width={362} height={132} seed={seed + 21}/>
        <svg width="362" height="132" viewBox="0 40 402 200" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
          <RouteLine path={DS_HERO_ROUTE} progress={1} width={4}/>
          <EndpointDot x={DS_HERO_ROUTE[0][0]} y={DS_HERO_ROUTE[0][1]} color={T.driving} size={11}/>
          <EndpointDot x={DS_HERO_ROUTE[DS_HERO_ROUTE.length - 1][0]} y={DS_HERO_ROUTE[DS_HERO_ROUTE.length - 1][1]} color={T.gold} size={11}/>
        </svg>
        <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(180deg, rgba(10,10,10,0.2), rgba(10,10,10,0) 30%, rgba(18,16,12,0.7) 100%)' }}/>
        <div style={{ position: 'absolute', top: 12, left: 14, display: 'flex', alignItems: 'center', gap: 7 }}>
          <ArrowMark size={16}/>
          <span style={{ fontSize: 12, fontWeight: 600, color: '#fff', letterSpacing: 0.2, textShadow: '0 1px 6px rgba(0,0,0,0.7)' }}>myrobotaxi</span>
        </div>
      </div>
      <div style={{ background: 'linear-gradient(180deg, #14120c, #0f0e0a)', padding: '14px 16px 16px' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
          <span style={{ fontSize: 13, color: T.text, fontWeight: 600, letterSpacing: -0.2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{d.from} → {d.to}</span>
          <span style={{ fontSize: 10.5, color: T.textMuted, flexShrink: 0 }}>{dateLabel}</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 16, marginTop: 12 }}>
          <span style={{ fontFamily: T.fontNum, fontSize: 26, fontWeight: 300, color: T.text, letterSpacing: -1 }}>{d.miles.toFixed(1)}<span style={{ fontSize: 12, color: T.textMuted, marginLeft: 2 }}>mi</span></span>
          <span style={{ fontFamily: T.fontNum, fontSize: 26, fontWeight: 300, color: T.text, letterSpacing: -1 }}>{d.mins}<span style={{ fontSize: 12, color: T.textMuted, marginLeft: 2 }}>min</span></span>
          <span style={{ marginLeft: 'auto', display: 'inline-flex', alignItems: 'baseline', gap: 4, padding: '4px 10px', borderRadius: 999, background: 'rgba(201,168,76,0.14)', border: `0.5px solid rgba(201,168,76,0.3)` }}>
            <span style={{ fontFamily: T.fontNum, fontSize: 15, fontWeight: 500, color: T.gold, letterSpacing: -0.3 }}>{fsdPct}%</span>
            <span style={{ fontSize: 9.5, color: T.goldLight, letterSpacing: 0.6, textTransform: 'uppercase' }}>FSD</span>
          </span>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 6 · Invites / Share
// ─────────────────────────────────────────────────────────────
// Access levels offered when sharing your Tesla — cumulative: each tier includes the ones above it.
const SHARE_CAPS = [
  { key: 'live',    label: 'See live location' },
  { key: 'history', label: 'View trip & drive history' },
  { key: 'rides',   label: 'Request rides — send the car' },
];
const SHARE_ACCESS = {
  live:    { title: 'Live location',     desc: 'See where your Tesla is, in real time.', icon: 'location.fill', perm: 'Live location',     grants: 1 },
  history: { title: 'Live + history',    desc: 'Everything in Live, plus past trips & drives.', icon: 'clock.fill', perm: 'Live + history',    grants: 2 },
  rides:   { title: 'Can request rides', desc: 'Everything above, plus send the car to pick them up.', icon: 'car.fill', perm: 'Can request rides', grants: 3 },
};
function emailToName(email) {
  const local = (email.split('@')[0] || '').replace(/[._-]+/g, ' ').trim();
  const name = local.split(' ').filter(Boolean).map(w => w[0].toUpperCase() + w.slice(1)).join(' ');
  return name || email;
}

function InvitesScreen({ nav, setNav }) {
  const [email, setEmail] = uS('');
  const [pending, setPending] = uS(PENDING);
  const [viewers, setViewers] = uS(VIEWERS);
  const [confirmRevoke, setConfirmRevoke] = uS(null); // viewer pending access revocation
  const [revokedToast, setRevokedToast] = uS(null); // name shown in the “access revoked” toast
  const [confirmCancelInvite, setConfirmCancelInvite] = uS(null); // pending invite pending withdrawal
  const [confirmResend, setConfirmResend] = uS(null); // pending invite pending resend
  const [resentToast, setResentToast] = uS(null); // name shown in the “invite resent” toast
  // Send-invite flow
  const [sendStep, setSendStep] = uS(null); // null | 'config' | 'sending' | 'done'
  const [accessLevel, setAccessLevel] = uS('live');
  const [shareVehicleIds, setShareVehicleIds] = uS([VEHICLES[0].id]);
  const toggleVehicle = (id) => setShareVehicleIds(ids => ids.includes(id) ? (ids.length > 1 ? ids.filter(x => x !== id) : ids) : [...ids, id]);
  const [emailErr, setEmailErr] = uS(false);
  const [sentToast, setSentToast] = uS(null); // email shown in the “invite sent” toast
  const validEmail = /.+@.+\..+/.test(email.trim());

  const openSend = () => {
    if (!validEmail) { setEmailErr(true); setTimeout(() => setEmailErr(false), 500); return; }
    setAccessLevel('live'); setShareVehicleIds([VEHICLES[0].id]); setSendStep('config');
  };
  const doSend = () => {
    setSendStep('sending');
    setTimeout(() => {
      setSendStep('done');
      setTimeout(() => {
        const addr = email.trim();
        setPending(ps => [{ name: emailToName(addr), email: addr, sent: 'just now', perm: SHARE_ACCESS[accessLevel].perm }, ...ps]);
        setSentToast(addr); setSendStep(null); setEmail('');
        setTimeout(() => setSentToast(null), 2800);
      }, 950);
    }, 1150);
  };
  return (
    <div style={{ position: 'absolute', inset: 0, background: T.bg, display: 'flex', flexDirection: 'column' }}>
      <div style={{ padding: '74px 24px 18px' }}>
        <div style={{ fontSize: 28, fontWeight: 600, color: T.text, letterSpacing: -0.6, marginBottom: 4 }}>Share Your Tesla</div>
        <div style={{ fontSize: 13, color: T.textSec, fontWeight: 400 }}>Let friends and family see live location and trips.</div>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 104 }}>
        {/* Email + invite row */}
        <div style={{ padding: '0 24px 28px', display: 'flex', gap: 10 }}>
          <input value={email} onChange={(e) => setEmail(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && openSend()} placeholder="friend@example.com" style={{
            flex: 1, height: 44, padding: '0 14px', borderRadius: T.radiusInput,
            background: T.surface, border: `0.5px solid ${emailErr ? '#FF6B6B' : T.border}`,
            color: T.text, fontFamily: T.font, fontSize: 14, outline: 'none',
            animation: emailErr ? 'mrt-invite-shake .4s ease' : 'none', transition: 'border-color .2s',
          }}/>
          <Button fullWidth={false} variant="gold" style={{ width: 110 }} onClick={openSend}>Send</Button>
        </div>
        {/* Viewers */}
        <div style={{ padding: '0 24px 14px' }}><Label>Viewers · {viewers.length}</Label></div>
        {viewers.length === 0 &&
          <div style={{ padding: '0 24px 14px', fontSize: 13, color: T.textMuted }}>No one has access yet.</div>}
        {viewers.map(v => (
          <div key={v.email} style={{ padding: '12px 24px', display: 'flex', alignItems: 'center', gap: 14 }}>
            <Avatar name={v.name} online={v.online}/>
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 3 }}>
              <div style={{ fontSize: 14, color: T.text, fontWeight: 500 }}>{v.name}</div>
              <div style={{ fontSize: 11, color: T.textMuted, letterSpacing: 0.2 }}>{v.perm}</div>
            </div>
            <button onClick={() => setConfirmRevoke(v)} style={{ background: 'transparent', border: `0.5px solid ${T.border}`, borderRadius: 99, color: T.textSec, fontFamily: T.font, fontSize: 12, fontWeight: 500, padding: '5px 12px', cursor: 'pointer', WebkitTapHighlightColor: 'transparent' }}>Revoke</button>
          </div>
        ))}
        {/* Pending */}
        {pending.length > 0 && <div style={{ padding: '20px 24px 14px' }}><Label>Pending</Label></div>}
        {pending.map(p => (
          <div key={p.email} style={{ padding: '12px 24px', display: 'flex', alignItems: 'center', gap: 14 }}>
            <Avatar name={p.name}/>
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
              <div style={{ fontSize: 14, color: T.text, fontWeight: 500 }}>{p.name}</div>
              <div style={{ fontSize: 11, color: T.textMuted }}>{p.email} · {p.sent}</div>
            </div>
            <button onClick={() => setConfirmResend(p)} style={{ background: 'transparent', border: 'none', color: T.gold, fontSize: 12, padding: 6, cursor: 'pointer' }}>Resend</button>
            <button onClick={() => setConfirmCancelInvite(p)} style={{ background: 'transparent', border: 'none', color: T.textMuted, fontSize: 12, padding: 6, cursor: 'pointer' }}>Cancel</button>
          </div>
        ))}
      </div>
      <BottomNav current={nav} onChange={setNav}/>

      <style>{`@keyframes mrt-invite-shake { 0%,100% { transform: translateX(0); } 20%,60% { transform: translateX(-6px); } 40%,80% { transform: translateX(6px); } }`}</style>

      {/* Send-invite configuration sheet */}
      {sendStep && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 75, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
          <div onClick={() => sendStep === 'config' && setSendStep(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .22s ease-out both' }}/>
          <div style={{ position: 'relative', borderTopLeftRadius: 26, borderTopRightRadius: 26, padding: '14px 22px 28px',
            background: '#16161a', borderTop: `0.5px solid ${T.border}`, boxShadow: '0 -14px 50px rgba(0,0,0,0.6)',
            animation: 'mrt-sched-up .34s cubic-bezier(.32,.72,0,1) both' }}>
            <div style={{ width: 36, height: 4, background: T.elevated, borderRadius: 4, margin: '0 auto 18px' }}/>

            {sendStep === 'config' && <>
              <button onClick={() => setSendStep(null)} aria-label="Close" style={{ position: 'absolute', top: 16, right: 18, width: 28, height: 28, borderRadius: 14, background: T.elevated, border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <SFIcon name="xmark" size={11} color={T.textSec} weight={2}/>
              </button>
              <div style={{ fontSize: 21, fontWeight: 600, color: T.text, letterSpacing: -0.4, marginBottom: 4 }}>Invite to your Tesla</div>
              <div style={{ fontSize: 13, color: T.textSec, marginBottom: 18 }}>Choose what they can see and do.</div>

              {/* Recipient */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 13px', borderRadius: 14, background: T.surface, border: `0.5px solid ${T.border}`, marginBottom: 20 }}>
                <Avatar name={emailToName(email)} size={36}/>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 14, fontWeight: 600, color: T.text }}>{emailToName(email)}</div>
                  <div style={{ fontSize: 11.5, color: T.textMuted, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{email}</div>
                </div>
              </div>

              {/* Vehicles — select one or more */}
              <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 9 }}>
                <Label>Vehicles</Label>
                <span style={{ fontSize: 11, color: T.textMuted }}>Select one or more</span>
              </div>
              <div style={{ display: 'flex', gap: 8, marginBottom: 20 }}>
                {VEHICLES.map((v) => {
                  const on = shareVehicleIds.includes(v.id);
                  return (
                    <button key={v.id} onClick={() => toggleVehicle(v.id)} style={{ position: 'relative', flex: 1, textAlign: 'left', padding: '11px 13px', borderRadius: 13, cursor: 'pointer',
                      background: on ? `${T.gold}1a` : T.surface, border: `1px solid ${on ? `${T.gold}88` : T.border}`, WebkitTapHighlightColor: 'transparent' }}>
                      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                        <SFIcon name="car.fill" size={16} color={on ? T.gold : T.textSec}/>
                        <div style={{ width: 18, height: 18, borderRadius: 5, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
                          background: on ? T.gold : 'transparent', border: `1.5px solid ${on ? T.gold : T.border}` }}>
                          {on && <SFIcon name="checkmark" size={11} color="#1a1408" weight={2.6}/>}
                        </div>
                      </div>
                      <div style={{ fontSize: 13.5, fontWeight: 600, color: T.text, marginTop: 7 }}>{v.name}</div>
                      <div style={{ fontSize: 10.5, color: T.textMuted, marginTop: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{v.plate}</div>
                    </button>
                  );
                })}
              </div>

              {/* Access level — cumulative tiers */}
              <Label style={{ marginBottom: 9 }}>Access</Label>
              {Object.entries(SHARE_ACCESS).map(([k, a]) => {
                const on = accessLevel === k;
                return (
                  <button key={k} onClick={() => setAccessLevel(k)} style={{ display: 'flex', alignItems: 'center', gap: 13, width: '100%', textAlign: 'left', padding: '12px 14px', borderRadius: 14, marginBottom: 8, cursor: 'pointer',
                    background: on ? `${T.gold}14` : T.surface, border: `1px solid ${on ? `${T.gold}77` : T.border}`, WebkitTapHighlightColor: 'transparent' }}>
                    <div style={{ width: 34, height: 34, borderRadius: 10, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: on ? `${T.gold}22` : T.elevated }}>
                      <SFIcon name={a.icon} size={16} color={on ? T.gold : T.textSec}/>
                    </div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 14, fontWeight: 600, color: T.text }}>{a.title}</div>
                      <div style={{ fontSize: 11.5, color: T.textSec, marginTop: 2 }}>{a.desc}</div>
                    </div>
                    <div style={{ width: 20, height: 20, borderRadius: 10, flexShrink: 0, border: `1.5px solid ${on ? T.gold : T.border}`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                      {on && <div style={{ width: 10, height: 10, borderRadius: 5, background: T.gold }}/>}
                    </div>
                  </button>
                );
              })}

              {/* Cumulative access summary — makes clear exactly what's granted */}
              <div style={{ marginTop: 12, padding: '13px 15px', borderRadius: 13, background: T.surface, border: `0.5px solid ${T.border}` }}>
                <div style={{ fontSize: 11, color: T.textMuted, letterSpacing: 0.2, marginBottom: 9 }}>{emailToName(email).split(' ')[0]} will be able to:</div>
                {SHARE_CAPS.map((c, i) => {
                  const granted = i < SHARE_ACCESS[accessLevel].grants;
                  return (
                    <div key={c.key} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '3px 0' }}>
                      <div style={{ width: 16, height: 16, borderRadius: 8, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: granted ? `${T.gold}26` : 'transparent', border: granted ? 'none' : `1px solid ${T.border}` }}>
                        {granted && <SFIcon name="checkmark" size={10} color={T.gold} weight={2.6}/>}
                      </div>
                      <span style={{ fontSize: 12.5, color: granted ? T.text : T.textMuted, fontWeight: granted ? 500 : 400 }}>{c.label}</span>
                    </div>
                  );
                })}
              </div>

              <div style={{ marginTop: 14 }}>
                <Button variant="gold" onClick={doSend}>Send invite</Button>
              </div>
            </>}

            {sendStep === 'sending' && (
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '34px 0 26px' }}>
                <div style={{ width: 40, height: 40, borderRadius: 20, border: `3px solid ${T.gold}33`, borderTopColor: T.gold, animation: 'mrt-spin .8s linear infinite' }}/>
                <div style={{ fontSize: 15, fontWeight: 600, color: T.text, marginTop: 18 }}>Sending invite…</div>
                <div style={{ fontSize: 12.5, color: T.textMuted, marginTop: 4 }}>{email}</div>
                <style>{`@keyframes mrt-spin { to { transform: rotate(360deg); } }`}</style>
              </div>
            )}

            {sendStep === 'done' && (
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '30px 0 24px' }}>
                <div style={{ width: 56, height: 56, borderRadius: 28, background: T.gold, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: `0 8px 26px ${T.goldGlow6 || 'rgba(201,168,76,0.4)'}`, animation: 'mrt-check-pop .5s cubic-bezier(0.34,1.56,0.64,1) both' }}>
                  <SFIcon name="checkmark" size={28} color="#1a1408" weight={2.6}/>
                </div>
                <div style={{ fontSize: 17, fontWeight: 600, color: T.text, marginTop: 16 }}>Invite sent</div>
                <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 4, textAlign: 'center', maxWidth: 260 }}>We emailed {emailToName(email)} a link to join.</div>
                <style>{`@keyframes mrt-check-pop { 0% { transform: scale(0); } 60% { transform: scale(1.15); } 100% { transform: scale(1); } }`}</style>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Resend invite confirmation — positive (gold) */}
      {confirmResend && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 70, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 28 }}>
          <div onClick={() => setConfirmResend(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .2s ease-out both' }}/>
          <div style={{ position: 'relative', width: '100%', maxWidth: 300, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, boxShadow: '0 20px 60px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .28s cubic-bezier(.32,.72,0,1) both', textAlign: 'center' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: `${T.gold}22`, display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="paperplane.fill" size={19} color={T.gold}/>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Resend invite?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>
              We’ll email the invite to <span style={{ color: T.text, fontWeight: 600 }}>{confirmResend.email}</span> again.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <button onClick={() => {
                setPending(ps => ps.map(x => x.email === confirmResend.email ? { ...x, sent: 'just now' } : x));
                setResentToast(confirmResend.name); setConfirmResend(null);
                setTimeout(() => setResentToast(null), 2600);
              }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: 'none', cursor: 'pointer',
                background: T.gold, color: '#1a1408', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                WebkitTapHighlightColor: 'transparent',
              }}>Resend invite</button>
              <button onClick={() => setConfirmResend(null)} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: T.text, fontFamily: T.font, fontSize: 15, fontWeight: 500,
                WebkitTapHighlightColor: 'transparent',
              }}>Not now</button>
            </div>
          </div>
        </div>
      )}

      {/* Revoke-access confirmation — matches the cancel-reservation dialog */}
      {confirmRevoke && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 70, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 28 }}>
          <div onClick={() => setConfirmRevoke(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .2s ease-out both' }}/>
          <div style={{ position: 'relative', width: '100%', maxWidth: 300, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, boxShadow: '0 20px 60px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .28s cubic-bezier(.32,.72,0,1) both', textAlign: 'center' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="person.fill" size={20} color="#FF6B6B"/>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Revoke access?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>
              <span style={{ color: T.text, fontWeight: 600 }}>{confirmRevoke.name}</span> will no longer see your vehicle’s location or trips. You can re-invite them anytime.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <button onClick={() => { const nm = confirmRevoke.name; setViewers(vs => vs.filter(x => x.email !== confirmRevoke.email)); setConfirmRevoke(null); setRevokedToast(nm); setTimeout(() => setRevokedToast(null), 2800); }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: 'none', cursor: 'pointer',
                background: 'rgba(255,59,48,0.16)', color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                WebkitTapHighlightColor: 'transparent',
              }}>Revoke access</button>
              <button onClick={() => setConfirmRevoke(null)} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: T.text, fontFamily: T.font, fontSize: 15, fontWeight: 500,
                WebkitTapHighlightColor: 'transparent',
              }}>Keep access</button>
            </div>
          </div>
        </div>
      )}

      {/* Cancel invite confirmation — destructive (red), matches revoke dialog */}
      {confirmCancelInvite && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 70, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 28 }}>
          <div onClick={() => setConfirmCancelInvite(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .2s ease-out both' }}/>
          <div style={{ position: 'relative', width: '100%', maxWidth: 300, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, boxShadow: '0 20px 60px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .28s cubic-bezier(.32,.72,0,1) both', textAlign: 'center' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="envelope.fill" size={19} color="#FF6B6B"/>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Cancel invite?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>
              The invite to <span style={{ color: T.text, fontWeight: 600 }}>{confirmCancelInvite.name}</span> will be withdrawn. You can invite them again later.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <button onClick={() => { setPending(ps => ps.filter(x => x.email !== confirmCancelInvite.email)); setConfirmCancelInvite(null); }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: 'none', cursor: 'pointer',
                background: 'rgba(255,59,48,0.16)', color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                WebkitTapHighlightColor: 'transparent',
              }}>Cancel invite</button>
              <button onClick={() => setConfirmCancelInvite(null)} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: T.text, fontFamily: T.font, fontSize: 15, fontWeight: 500,
                WebkitTapHighlightColor: 'transparent',
              }}>Keep invite</button>
            </div>
          </div>
        </div>
      )}

      {/* Access-revoked toast */}
      {revokedToast && (
        <div style={{ position: 'absolute', left: 24, right: 24, bottom: 116, zIndex: 65, display: 'flex', alignItems: 'center', gap: 10, padding: '13px 16px', borderRadius: 14, background: '#22221f', border: `0.5px solid ${T.gold}55`, boxShadow: '0 12px 36px rgba(0,0,0,0.5)', animation: 'mrt-sched-up .3s cubic-bezier(.32,.72,0,1) both' }}>
          <SFIcon name="checkmark" size={15} color={T.gold} weight={2.4}/>
          <span style={{ fontSize: 13.5, color: T.text, fontWeight: 500 }}>Access revoked for {revokedToast}</span>
        </div>
      )}

      {/* Invite-resent toast */}
      {resentToast && (
        <div style={{ position: 'absolute', left: 24, right: 24, bottom: 116, zIndex: 65, display: 'flex', alignItems: 'center', gap: 10, padding: '13px 16px', borderRadius: 14, background: '#22221f', border: `0.5px solid ${T.gold}55`, boxShadow: '0 12px 36px rgba(0,0,0,0.5)', animation: 'mrt-sched-up .3s cubic-bezier(.32,.72,0,1) both' }}>
          <SFIcon name="checkmark" size={15} color={T.gold} weight={2.4}/>
          <span style={{ fontSize: 13.5, color: T.text, fontWeight: 500 }}>Invite resent to {resentToast}</span>
        </div>
      )}

      {/* Invite-sent toast */}
      {sentToast && (
        <div style={{ position: 'absolute', left: 24, right: 24, bottom: 116, zIndex: 65, display: 'flex', alignItems: 'center', gap: 10, padding: '13px 16px', borderRadius: 14, background: '#22221f', border: `0.5px solid ${T.gold}55`, boxShadow: '0 12px 36px rgba(0,0,0,0.5)', animation: 'mrt-sched-up .3s cubic-bezier(.32,.72,0,1) both' }}>
          <SFIcon name="checkmark" size={15} color={T.gold} weight={2.4}/>
          <span style={{ fontSize: 13.5, color: T.text, fontWeight: 500, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>Invite sent to {sentToast}</span>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 7 · Settings
// ─────────────────────────────────────────────────────────────
function SettingsScreen({ nav, setNav, onAddTesla, onSignOut }) {
  const [toggles, setT] = uS({ start: true, end: true, charge: false, viewer: true });
  // Who currently has access to the owner's vehicles — revocable.
  const [viewers, setViewers] = uS(VIEWERS);
  const [confirmRevoke, setConfirmRevoke] = uS(null); // viewer pending access revocation
  const [revokedToast, setRevokedToast] = uS(null); // name shown in the “access revoked” toast
  // Linked vehicles — with a designated primary; both manageable.
  const [vehicles, setVehicles] = uS(VEHICLES);
  const [primaryId, setPrimaryId] = uS(VEHICLES[0].id);
  const [vehicleDetail, setVehicleDetail] = uS(null); // vehicle row tapped open
  const [confirmUnlink, setConfirmUnlink] = uS(null);  // vehicle pending unlink
  const [confirmSignOut, setConfirmSignOut] = uS(false);

  return (
    <div style={{ position: 'absolute', inset: 0, background: T.bg, display: 'flex', flexDirection: 'column' }}>
      <div style={{ padding: '74px 24px 18px' }}>
        <div style={{ fontSize: 28, fontWeight: 600, color: T.text, letterSpacing: -0.6 }}>Settings</div>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 104 }}>
        <div style={{ padding: '0 24px 24px' }}>
          <Label style={{ marginBottom: 10 }}>Profile</Label>
          <div style={{ fontSize: 16, color: T.text, fontWeight: 500 }}>Alex Cole</div>
          <div style={{ fontSize: 13, color: T.textSec, marginTop: 2 }}>alex@cole.run</div>
        </div>
        <Divider pad={0}/>

        {/* Tesla account — all linked vehicles */}
        <div style={{ padding: '20px 24px 8px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <Label>Tesla Account</Label>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <PulseDot color={T.driving} size={6}/>
            <span style={{ fontSize: 11, color: T.textSec, letterSpacing: 0.2 }}>Linked · synced 14s ago</span>
          </div>
        </div>
        <div style={{ padding: '0 24px 8px' }}>
          {vehicles.map((v, i) => {
            const isPrimary = v.id === primaryId;
            return (
            <button key={v.id} onClick={() => setVehicleDetail(v)} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '12px 0', width: '100%', textAlign: 'left', background: 'transparent', cursor: 'pointer',
              border: 'none', borderTop: i === 0 ? 'none' : `0.5px solid ${T.border}`, WebkitTapHighlightColor: 'transparent' }}>
              <div style={{ width: 40, height: 40, borderRadius: 12, background: T.surface, border: `0.5px solid ${T.border}`,
                display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                <SFIcon name="car.fill" size={19} color={isPrimary ? T.gold : T.textSec}/>
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: 15, color: T.text, fontWeight: 600, letterSpacing: -0.2 }}>{v.name}</span>
                  {isPrimary && <span style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 0.5, color: T.gold, background: `${T.gold}1f`, padding: '2px 7px', borderRadius: 99, textTransform: 'uppercase' }}>Primary</span>}
                </div>
                <div style={{ fontSize: 11.5, color: T.textMuted, marginTop: 2 }}>{v.model} · {v.plate}</div>
              </div>
              <SFIcon name="chevron.right" size={13} color={T.textMuted}/>
            </button>
            );
          })}
        </div>
        <div style={{ padding: '4px 24px 20px' }}>
          <button onClick={onAddTesla} style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'transparent', border: 'none', cursor: 'pointer', padding: '6px 0', color: T.gold, fontFamily: T.font, fontSize: 13.5, fontWeight: 600 }}>
            <SFIcon name="plus" size={13} color={T.gold} weight={2.2}/>
            <span>Add another Tesla</span>
          </button>
        </div>
        <Divider pad={0}/>

        {/* Sharing — who can see / use the owner's vehicles */}
        <div style={{ padding: '20px 24px 10px', display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
          <Label>Shared with</Label>
          <span style={{ fontSize: 11, color: T.textMuted }}>{viewers.length} {viewers.length === 1 ? 'person' : 'people'}</span>
        </div>
        {viewers.length === 0 &&
          <div style={{ padding: '0 24px 14px', fontSize: 13, color: T.textMuted }}>No one has access yet.</div>}
        {viewers.map(v => (
          <div key={v.email} style={{ padding: '11px 24px', display: 'flex', alignItems: 'center', gap: 13 }}>
            <Avatar name={v.name} online={v.online}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 14, color: T.text, fontWeight: 500 }}>{v.name}</div>
              <div style={{ fontSize: 11, color: T.textMuted, letterSpacing: 0.2, marginTop: 2 }}>{v.perm}</div>
            </div>
            <button onClick={() => setConfirmRevoke(v)}
              style={{ background: 'transparent', border: `0.5px solid ${T.border}`, borderRadius: 99, color: T.textSec, fontFamily: T.font, fontSize: 12, fontWeight: 500, padding: '5px 12px', cursor: 'pointer', WebkitTapHighlightColor: 'transparent' }}>Revoke</button>
          </div>
        ))}
        <div style={{ padding: '8px 24px 20px' }}>
          <button onClick={() => setNav('invites')} style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'transparent', border: 'none', cursor: 'pointer', padding: '6px 0', color: T.gold, fontFamily: T.font, fontSize: 13.5, fontWeight: 600 }}>
            <SFIcon name="plus" size={13} color={T.gold} weight={2.2}/>
            <span>Invite someone</span>
          </button>
        </div>
        <Divider pad={0}/>

        <div style={{ padding: '20px 24px' }}>
          <Label style={{ marginBottom: 14 }}>Notifications</Label>
          {[
            ['Drive started',     'start'],
            ['Drive completed',   'end'],
            ['Charging complete', 'charge'],
            ['Viewer joined',     'viewer'],
          ].map(([label, key]) => (
            <div key={key} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 0' }}>
              <span style={{ fontSize: 14, color: T.text }}>{label}</span>
              <Toggle value={toggles[key]} onChange={(v) => setT({ ...toggles, [key]: v })}/>
            </div>
          ))}
        </div>
        <Divider pad={0}/>
        <div style={{ padding: '24px', display: 'flex', justifyContent: 'flex-start' }}>
          <button onClick={() => setConfirmSignOut(true)} style={{ background: 'transparent', border: 'none', color: '#FF6B6B', fontSize: 14, fontWeight: 500, padding: 0, cursor: 'pointer', WebkitTapHighlightColor: 'transparent' }}>Sign out</button>
        </div>
        <div style={{ padding: '20px 24px 40px', textAlign: 'center', fontSize: 11, color: T.textMuted, letterSpacing: 0.4 }}>
          MyRoboTaxi v1.0 (24)
        </div>
      </div>
      <BottomNav current={nav} onChange={setNav}/>

      {/* Sign-out confirmation */}
      {confirmSignOut && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 80, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 28 }}>
          <div onClick={() => setConfirmSignOut(false)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .2s ease-out both' }}/>
          <div style={{ position: 'relative', width: '100%', maxWidth: 300, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, boxShadow: '0 20px 60px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .28s cubic-bezier(.32,.72,0,1) both', textAlign: 'center' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="arrow.up.right" size={20} color="#FF6B6B"/>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Sign out?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>
              You'll need to sign in again to access your Tesla. Your linked vehicles stay connected.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <button onClick={() => { setConfirmSignOut(false); onSignOut && onSignOut(); }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: 'none', cursor: 'pointer',
                background: 'rgba(255,59,48,0.16)', color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                WebkitTapHighlightColor: 'transparent',
              }}>Sign out</button>
              <button onClick={() => setConfirmSignOut(false)} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: T.text, fontFamily: T.font, fontSize: 15, fontWeight: 500,
                WebkitTapHighlightColor: 'transparent',
              }}>Cancel</button>
            </div>
          </div>
        </div>
      )}

      {/* Vehicle detail sheet — explains Primary + lets you set primary / unlink */}
      {vehicleDetail && (() => {
        const v = vehicleDetail; const isPrimary = v.id === primaryId;
        return (
        <div style={{ position: 'absolute', inset: 0, zIndex: 75, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
          <div onClick={() => setVehicleDetail(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .22s ease-out both' }}/>
          <div style={{ position: 'relative', borderTopLeftRadius: 26, borderTopRightRadius: 26, padding: '14px 22px 28px',
            background: '#16161a', borderTop: `0.5px solid ${T.border}`, boxShadow: '0 -14px 50px rgba(0,0,0,0.6)',
            animation: 'mrt-sched-up .34s cubic-bezier(.32,.72,0,1) both' }}>
            <div style={{ width: 36, height: 4, background: T.elevated, borderRadius: 4, margin: '0 auto 18px' }}/>
            <button onClick={() => setVehicleDetail(null)} aria-label="Close" style={{ position: 'absolute', top: 16, right: 18, width: 28, height: 28, borderRadius: 14, background: T.elevated, border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <SFIcon name="xmark" size={11} color={T.textSec} weight={2}/>
            </button>

            {/* Header */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 18 }}>
              <div style={{ width: 52, height: 52, borderRadius: 15, background: T.surface, border: `0.5px solid ${T.border}`, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                <SFIcon name="car.fill" size={24} color={isPrimary ? T.gold : T.textSec}/>
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: 19, fontWeight: 600, color: T.text, letterSpacing: -0.3 }}>{v.name}</span>
                  {isPrimary && <span style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 0.5, color: T.gold, background: `${T.gold}1f`, padding: '2px 7px', borderRadius: 99, textTransform: 'uppercase' }}>Primary</span>}
                </div>
                <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 2 }}>{v.model} · {v.plate}</div>
              </div>
            </div>

            {/* What "Primary" means */}
            <div style={{ display: 'flex', gap: 11, padding: '13px 15px', borderRadius: 14, background: T.surface, border: `0.5px solid ${T.border}`, marginBottom: 18 }}>
              <SFIcon name="checkmark" size={15} color={T.gold} weight={2.4}/>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 13, fontWeight: 600, color: T.text, marginBottom: 3 }}>{isPrimary ? 'This is your primary Tesla' : 'About primary'}</div>
                <div style={{ fontSize: 12, color: T.textSec, lineHeight: 1.5 }}>
                  Your primary Tesla is the one shown by default on the map and used for new ride requests and sharing.
                </div>
              </div>
            </div>

            {/* Actions */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              {!isPrimary && (
                <button onClick={() => { setPrimaryId(v.id); setVehicleDetail(null); }} style={{
                  width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.gold}66`, cursor: 'pointer',
                  background: `${T.gold}14`, color: T.gold, fontFamily: T.font, fontSize: 15, fontWeight: 600,
                  display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, WebkitTapHighlightColor: 'transparent',
                }}><SFIcon name="checkmark" size={14} color={T.gold} weight={2.4}/>Set as primary</button>
              )}
              <button onClick={() => { setVehicleDetail(null); setConfirmUnlink(v); }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, WebkitTapHighlightColor: 'transparent',
              }}><SFIcon name="xmark" size={14} color="#FF6B6B" weight={2}/>Unlink this Tesla</button>
            </div>
          </div>
        </div>
        );
      })()}

      {/* Unlink confirmation */}
      {confirmUnlink && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 80, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 28 }}>
          <div onClick={() => setConfirmUnlink(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .2s ease-out both' }}/>
          <div style={{ position: 'relative', width: '100%', maxWidth: 300, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, boxShadow: '0 20px 60px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .28s cubic-bezier(.32,.72,0,1) both', textAlign: 'center' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="car.fill" size={20} color="#FF6B6B"/>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Unlink {confirmUnlink.name}?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>
              MyRoboTaxi will lose access to this Tesla and everyone you've shared it with will be removed. You can re-add it anytime.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <button onClick={() => {
                const remaining = vehicles.filter(x => x.id !== confirmUnlink.id);
                setVehicles(remaining);
                if (confirmUnlink.id === primaryId && remaining[0]) setPrimaryId(remaining[0].id);
                setConfirmUnlink(null);
              }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: 'none', cursor: 'pointer',
                background: 'rgba(255,59,48,0.16)', color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                WebkitTapHighlightColor: 'transparent',
              }}>Unlink Tesla</button>
              <button onClick={() => setConfirmUnlink(null)} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: T.text, fontFamily: T.font, fontSize: 15, fontWeight: 500,
                WebkitTapHighlightColor: 'transparent',
              }}>Keep linked</button>
            </div>
          </div>
        </div>
      )}

      {/* Access-revoked toast */}
      {revokedToast && (
        <div style={{ position: 'absolute', left: 24, right: 24, bottom: 116, zIndex: 65, display: 'flex', alignItems: 'center', gap: 10, padding: '13px 16px', borderRadius: 14, background: '#22221f', border: `0.5px solid ${T.gold}55`, boxShadow: '0 12px 36px rgba(0,0,0,0.5)', animation: 'mrt-sched-up .3s cubic-bezier(.32,.72,0,1) both' }}>
          <SFIcon name="checkmark" size={15} color={T.gold} weight={2.4}/>
          <span style={{ fontSize: 13.5, color: T.text, fontWeight: 500 }}>Access revoked for {revokedToast}</span>
        </div>
      )}

      {/* Revoke-access confirmation — matches the cancel-reservation dialog */}
      {confirmRevoke && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 70, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 28 }}>
          <div onClick={() => setConfirmRevoke(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .2s ease-out both' }}/>
          <div style={{ position: 'relative', width: '100%', maxWidth: 300, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, boxShadow: '0 20px 60px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .28s cubic-bezier(.32,.72,0,1) both', textAlign: 'center' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="person.fill" size={20} color="#FF6B6B"/>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Revoke access?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>
              <span style={{ color: T.text, fontWeight: 600 }}>{confirmRevoke.name}</span> will no longer see your vehicle’s location or trips. You can re-invite them anytime.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <button onClick={() => { const nm = confirmRevoke.name; setViewers(vs => vs.filter(x => x.email !== confirmRevoke.email)); setConfirmRevoke(null); setRevokedToast(nm); setTimeout(() => setRevokedToast(null), 2800); }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: 'none', cursor: 'pointer',
                background: 'rgba(255,59,48,0.16)', color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                WebkitTapHighlightColor: 'transparent',
              }}>Revoke access</button>
              <button onClick={() => setConfirmRevoke(null)} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: T.text, fontFamily: T.font, fontSize: 15, fontWeight: 500,
                WebkitTapHighlightColor: 'transparent',
              }}>Keep access</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// RotatingText — cycles through phrases with a soft slide-up/blur reveal.
// ─────────────────────────────────────────────────────────────
function RotatingText({ items, interval = 2800, style }) {
  const [idx, setIdx] = uS(0);
  uE(() => {
    if (items.length < 2) return;
    const id = setInterval(() => setIdx(i => (i + 1) % items.length), interval);
    return () => clearInterval(id);
  }, [items.length, interval]);
  return (
    <span style={{ display: 'inline-block', position: 'relative', ...style }}>
      <span key={idx} className="mrt-ph-rotate" style={{ display: 'inline-block', whiteSpace: 'nowrap' }}>{items[idx]}</span>
    </span>
  );
}

// ─────────────────────────────────────────────────────────────
// 8 · Anonymous Shared Viewer (simplified)
// ─────────────────────────────────────────────────────────────
function SharedViewerScreen({
  progress, battery, speed, driving,
  riderName = 'Sam',
  requestState = 'idle', setRequestState,
  requestDest, setRequestDest,
  requestPassenger = null, setRequestPassenger,
  nav = 'shared', setNav,
  docFreeze = false, // docs-only: freeze the sending countdown so it doesn't auto-advance
  initialPhase, // docs-only: mount the request sheet directly into a phase (search/review/pinDrop)
}) {
  const v = VEHICLES[0];
  const route = buildSampleRoute();
  const S = useSurfaces();
  // Local sheet phase — drives the expanding sheet's height + content
  const [phase, setPhase] = React.useState(initialPhase || 'idle');
  const [fleetIdx, setFleetIdx] = React.useState(0);
  const [schedule, setSchedule] = React.useState(null); // { day, time } | null
  const [rider, setRider] = React.useState('me');        // 'me' | 'other'
  const setPassenger = setRequestPassenger || (() => {});
  // Passenger only applies when requesting for someone else. Keep cross-side
  // state clean so a passenger from a prior request never leaks into a 'Me'
  // ride (the owner sheet reads requestPassenger directly).
  React.useEffect(() => {
    if (rider === 'me' && requestPassenger) setPassenger(null);
  }, [rider, requestPassenger]);
  const [pickup, setPickup] = React.useState(null);     // { label } from map pin | null
  const [pinReturn, setPinReturn] = React.useState('search'); // where pin-drop confirm goes: 'search' | 'review'
  const [pan, setPan] = React.useState({ x: 0, y: 0 }); // map pan while dropping a pin
  const [dragging, setDragging] = React.useState(false);
  const [scheduledRides, setScheduledRides] = React.useState([]); // committed upcoming rides
  const panRef = React.useRef({ on: false, sx: 0, sy: 0, bx: 0, by: 0 });
  const sel = FLEET[fleetIdx];
  const pinMode = phase === 'pinDrop';
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

  // Fake reverse-geocode: pan offset → a plausible SF pickup address
  const PIN_SPOTS = ['Folsom & 2nd St', 'Embarcadero Plaza', 'Howard & Spear St', 'Mission & Main St', 'Beale St · Rincon Hill', 'Steuart St · Ferry'];
  const pinAddress = React.useMemo(() => {
    const d = Math.round((Math.abs(pan.x) + Math.abs(pan.y)) / 24);
    return PIN_SPOTS[Math.min(PIN_SPOTS.length - 1, d)];
  }, [pan]);

  // Reset pan whenever we leave pin-drop
  React.useEffect(() => { if (phase !== 'pinDrop') { setPan({ x: 0, y: 0 }); setDragging(false); } }, [phase]);

  const onPanDown = (e) => {
    panRef.current = { on: true, sx: e.clientX, sy: e.clientY, bx: pan.x, by: pan.y };
    setDragging(true);
    e.currentTarget.setPointerCapture?.(e.pointerId);
  };
  const onPanMove = (e) => {
    if (!panRef.current.on) return;
    setPan({
      x: clamp(panRef.current.bx + (e.clientX - panRef.current.sx), -78, 78),
      y: clamp(panRef.current.by + (e.clientY - panRef.current.sy), -78, 78),
    });
  };
  const onPanUp = () => { panRef.current.on = false; setDragging(false); };

  // Commit a scheduled ride → adds to the upcoming list on the idle sheet
  const DAY_ORDER = ['Today', 'Tomorrow', 'Thu', 'Fri', 'Sat', 'Sun', 'Mon'];
  const toMin = (t) => { const m = (t || '').match(/(\d+):(\d+)\s*(AM|PM)/i); if (!m) return 0; let h = parseInt(m[1], 10) % 12; if (/pm/i.test(m[3])) h += 12; return h * 60 + parseInt(m[2], 10); };
  const sortedRides = React.useMemo(() => [...scheduledRides].sort((a, b) => {
    const da = DAY_ORDER.indexOf(a.schedule.day), db = DAY_ORDER.indexOf(b.schedule.day);
    return da !== db ? da - db : toMin(a.schedule.time) - toMin(b.schedule.time);
  }), [scheduledRides]);

  const commitSchedule = () => {
    const id = 'sr' + Date.now();
    setScheduledRides(rs => [...rs, { id, dest: requestDest, schedule, owner: sel.owner, vehicle: sel.name, etaMin: sel.etaMin, status: 'pending' }]);
    setSchedule(null);
    setPhase('idle');
    // Simulate the owner reviewing the scheduled request, then accepting
    setTimeout(() => {
      setScheduledRides(rs => rs.map(r => r.id === id ? { ...r, status: 'accepted' } : r));
    }, 5000);
  };
  // Tap an upcoming ride → review it (so it can be changed or re-confirmed)
  const viewScheduled = (ride) => {
    setRequestDest(ride.dest);
    setSchedule(ride.schedule);
    setScheduledRides(rs => rs.filter(r => r.id !== ride.id));
    setPhase('review');
  };
  const cancelScheduled = (id) => setScheduledRides(rs => rs.filter(r => r.id !== id));
  const [confirmCancel, setConfirmCancel] = React.useState(null); // ride pending cancel confirmation

  // Active (now) request — track when it was sent so the status persists if minimized
  const [requestSentAt, setRequestSentAt] = React.useState(null);
  React.useEffect(() => {
    if (requestState === 'pending') { setRequestSentAt(t => t || Date.now()); }
    else if (requestState === 'idle') { setRequestSentAt(null); }
  }, [requestState]);

  // Trip progress is driven by the Tweaks “Trip progress” slider — no auto-animation.
  // A fresh in-app accept overrides it to a to-pickup value until the slider moves.
  const [progressOverride, setProgressOverride] = React.useState(null);
  React.useEffect(() => { setProgressOverride(null); }, [progress]);
  React.useEffect(() => { if (requestState === 'idle') setProgressOverride(null); }, [requestState]);
  const trackProgress = progressOverride != null ? progressOverride : progress;
  // Interpolate the car position along the route at the current progress.
  const carPt = React.useMemo(() => {
    if (!route || route.length < 2) return null;
    let total = 0; const segs = [];
    for (let i = 1; i < route.length; i++) { const l = Math.hypot(route[i][0] - route[i - 1][0], route[i][1] - route[i - 1][1]); segs.push(l); total += l; }
    let d = Math.max(0, Math.min(1, trackProgress)) * total;
    for (let i = 0; i < segs.length; i++) { if (d <= segs[i]) { const t = segs[i] ? d / segs[i] : 0; return [route[i][0] + (route[i + 1][0] - route[i][0]) * t, route[i][1] + (route[i + 1][1] - route[i][1]) * t]; } d -= segs[i]; }
    return route[route.length - 1];
  }, [trackProgress, route]);
  const reqActive = requestState && requestState !== 'idle';
  const reqMeta = {
    pending:  { label: 'Request sent',     sub: `Waiting for ${sel.owner}`,        color: T.gold,    pulse: true },
    accepted: { label: 'Request accepted', sub: `${sel.owner} is sending the car`, color: T.driving, pulse: false },
    rejected: { label: 'Request declined', sub: `${sel.owner} can’t right now`,     color: '#FF6B6B', pulse: false },
  }[requestState];
  const reopenRequest = () => setPhase(requestState === 'pending' ? 'pending' : requestState === 'accepted' ? 'tracking' : 'search');

  // Time-of-day greeting (premium glow reveal on the idle sheet)
  const greeting = React.useMemo(() => {
    const h = new Date().getHours();
    return h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
  }, []);
  // Rotating search-bar placeholder: destination prompt ⇄ ride availability
  const placeholders = schedule
    ? ['Where to?', `Pickup ${schedule.day} · ${schedule.time}`]
    : ['Where to?', `A ride is ${sel.etaMin} min away`];

  // Auto-collapse to idle once outcome state is acknowledged externally
  React.useEffect(() => {
    if (initialPhase) return; // docs: hold the requested phase
    if (requestState === 'idle' && phase !== 'idle' && phase !== 'search' && phase !== 'review') {
      setPhase('idle');
    }
  }, [requestState]);

  const showPreviewRoute = phase === 'review' || phase === 'pending';
  const accepted = requestState === 'accepted';
  const destLabel = (accepted || showPreviewRoute) ? (requestDest?.label || 'Pescadero') : 'Pescadero';
  // Visible map area above the request sheet — the route is fitted into this so the whole trip shows.
  const previewMapH = (phase === 'pending' ? 526 : 440) - 12;
  // Visible map height for the accepted/tracking route fit (whole route shown).
  const liveMapH = phase === 'tracking' ? 478 : 648;

  // No blend: the map stays a real map and the card sits on it as a clean,
  // defined panel. Only a faint bottom darkening so the card's top edge + shadow
  // read cleanly against the map.
  const mapFade = 'linear-gradient(180deg, rgba(10,10,10,0) 64%, rgba(10,10,10,0.18) 84%, rgba(10,10,10,0.42) 100%)';

  return (
    <div style={{ position: 'absolute', inset: 0, background: '#070707', overflow: 'hidden' }}>
      <div style={{
        position: 'absolute', inset: 0, transformOrigin: 'center',
        transform: pinMode ? `scale(1.18) translate(${pan.x}px, ${pan.y}px)` : 'none',
        transition: dragging ? 'none' : 'transform .4s cubic-bezier(.32,.72,0,1)',
      }}>
        <MapBackground width={402} height={874} seed={91}/>
      </div>

      {/* Black gradient — the map stays fully visible across the upper screen,
         then dissolves into solid #0A0A0A right at the card's top edge (anchored
         to the real card height per phase) so the map fades straight into the
         card with no black band above it and no map showing behind content. */}
      <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', background: mapFade }}/>

      {/* Pin-drop: drag surface + centered pin + address while choosing pickup */}
      {pinMode && (
        <>
          <div onPointerDown={onPanDown} onPointerMove={onPanMove} onPointerUp={onPanUp} onPointerCancel={onPanUp}
            style={{ position: 'absolute', left: 0, right: 0, top: 0, height: 600, zIndex: 24, cursor: dragging ? 'grabbing' : 'grab', touchAction: 'none' }}/>
          {/* ground shadow */}
          <div style={{ position: 'absolute', left: '50%', top: 300, width: 14, height: 5, borderRadius: '50%', background: 'rgba(0,0,0,0.5)', zIndex: 25, pointerEvents: 'none', transform: `translate(-50%,-50%) scale(${dragging ? 0.65 : 1})`, transition: 'transform .15s' }}/>
          {/* pin */}
          <svg width="34" height="46" viewBox="0 0 34 46" style={{ position: 'absolute', left: '50%', top: 300, zIndex: 26, pointerEvents: 'none', transform: `translate(-50%,-100%) translateY(${dragging ? -7 : 0}px)`, transition: 'transform .15s', filter: 'drop-shadow(0 5px 7px rgba(0,0,0,0.5))' }}>
            <path d="M17 1.5a13 13 0 0 0-13 13c0 9.5 13 29.5 13 29.5s13-20 13-29.5a13 13 0 0 0-13-13z" fill={T.gold} stroke="#1a1408" strokeWidth="1.4"/>
            <circle cx="17" cy="14.5" r="4.8" fill="#1a1408"/>
          </svg>
          {/* address chip above the pin */}
          <div style={{ position: 'absolute', left: '50%', top: 300 - 56, transform: 'translate(-50%,-100%)', zIndex: 26, pointerEvents: 'none', padding: '6px 12px', borderRadius: 999, background: 'rgba(20,20,22,0.92)', border: `0.5px solid ${T.border}`, boxShadow: '0 4px 14px rgba(0,0,0,0.4)', whiteSpace: 'nowrap' }}>
            <span style={{ fontSize: 12.5, color: T.text, fontWeight: 600, letterSpacing: -0.1 }}>{pinAddress}</span>
          </div>
        </>
      )}

      {/* Live route (accepted): whole route fitted in the visible map above the
         sheet so the rider can see the full path; car position follows the
         Trip-progress tweak. */}
      {accepted && (
        <svg width="402" height={liveMapH} viewBox="-44 -34 480 668" preserveAspectRatio="xMidYMid meet" style={{ position: 'absolute', top: 0, left: 0, pointerEvents: 'none' }}>
          <RouteLine path={route} progress={trackProgress} width={6} glow/>
          <EndpointDot x={route[0][0]} y={route[0][1]} color={T.driving} size={14}/>
          <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={16}/>
          {carPt && (
            <g>
              <circle cx={carPt[0]} cy={carPt[1]} r={16} fill={T.driving} opacity={0.20}/>
              <circle cx={carPt[0]} cy={carPt[1]} r={8.5} fill={T.driving} stroke="#0A0A0A" strokeWidth={2.5}/>
            </g>
          )}
        </svg>
      )}
      {/* Preview route: zoomed out so the WHOLE route is visible above the sheet */}
      {showPreviewRoute && (
        <svg width="402" height={previewMapH} viewBox="-36 -28 464 646" preserveAspectRatio="xMidYMid meet" style={{ position: 'absolute', top: 0, left: 0, pointerEvents: 'none' }}>
          <RouteLine path={route} progress={1} width={7} glow/>
          <EndpointDot x={route[0][0]} y={route[0][1]} color={T.driving} size={14}/>
          <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={16}/>
        </svg>
      )}
      <CompassLabels/>

      {/* Expanding sheet: idle stats OR request flow content */}
      <ExpandingRequestSheet
        phase={phase} setPhase={setPhase}
        dest={requestDest} setDest={setRequestDest}
        vehicleName={sel.name} requesterName={sel.owner} riderName={riderName}
        fleet={FLEET} fleetIdx={fleetIdx} setFleetIdx={setFleetIdx}
        schedule={schedule} setSchedule={setSchedule}
        rider={rider} setRider={setRider}
        passenger={requestPassenger} setPassenger={setPassenger}
        pickup={pickup} pinAddress={pinAddress} setPinReturn={setPinReturn}
        onMapConfirm={() => { setPickup({ label: pinAddress }); setPhase(pinReturn); }}
        onMapCancel={() => setPhase('search')}
        onSchedule={commitSchedule}
        sentAt={requestSentAt}
        idleHeight={(reqActive ? 246 : 286) + (scheduledRides.length ? 26 + Math.min(scheduledRides.length, 2) * 60 : 0)}
        driving={driving} progress={progress} trackProgress={trackProgress} battery={battery} speed={speed}
        requestState={requestState} setRequestState={setRequestState}
        onAutoAccept={() => { setProgressOverride(0.06); setRequestState && setRequestState('accepted'); }}
        navHeight={0}
        docFreeze={docFreeze}
      >
        {/* IDLE content: time-of-day greeting with a premium glow reveal */}
        <div style={{ marginBottom: 16 }}>
          <div className="mrt-greet" style={{ fontSize: 21, fontWeight: 500, color: T.text, letterSpacing: -0.4, lineHeight: 1.2 }}>
            {greeting}, <span className="mrt-greet-name" style={{ color: T.gold, fontWeight: 600 }}>{riderName}</span>
          </div>
        </div>

        {/* Active 'now' request status — shown after minimizing the pending sheet */}
        {reqActive && reqMeta && (
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8, width: '100%', marginBottom: 14,
            padding: '11px 13px', borderRadius: 14,
            background: `${reqMeta.color}1a`, border: `0.5px solid ${reqMeta.color}55`,
          }}>
            <button onClick={reopenRequest} style={{
              display: 'flex', alignItems: 'center', gap: 12, flex: 1, minWidth: 0,
              background: 'transparent', border: 'none', cursor: 'pointer', textAlign: 'left', padding: 0,
              WebkitTapHighlightColor: 'transparent',
            }}>
              <span style={{ position: 'relative', width: 30, height: 30, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                {reqMeta.pulse && <span className="mrt-ready-dot" style={{ position: 'absolute', inset: 0, borderRadius: 15, border: `1.5px solid ${reqMeta.color}` }}/>}
                <span style={{ width: 18, height: 18, borderRadius: 9, background: reqMeta.color, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                  <SFIcon name={requestState === 'accepted' ? 'checkmark' : requestState === 'rejected' ? 'xmark' : 'paperplane.fill'} size={9} color="#1a1408" weight={2.4}/>
                </span>
              </span>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14, color: T.text, fontWeight: 600, letterSpacing: -0.2 }}>{reqMeta.label}</div>
                <div style={{ fontSize: 12, color: T.textSec, marginTop: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                  {reqMeta.sub} · {requestDest?.label || 'your ride'}
                </div>
              </div>
            </button>
            {requestState === 'pending' ? (
              <button onClick={() => { setRequestState('idle'); setPhase('idle'); }} aria-label="Cancel request" style={{
                width: 28, height: 28, borderRadius: 14, background: 'rgba(255,107,107,0.14)', border: 'none',
                cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
                WebkitTapHighlightColor: 'transparent',
              }}>
                <SFIcon name="xmark" size={11} color="#FF6B6B" weight={2.4}/>
              </button>
            ) : (
              <SFIcon name="chevron.right" size={13} color={T.textMuted}/>
            )}
          </div>
        )}
        {sortedRides.length > 0 && (
          <div style={{ marginBottom: 14 }}>
            <div style={{ fontSize: 10.5, color: T.gold, letterSpacing: 0.9, fontWeight: 700, textTransform: 'uppercase', marginBottom: 7, paddingLeft: 2 }}>
              Upcoming · {sortedRides.length}
            </div>
            <div className="mrt-noscroll" style={{ display: 'flex', flexDirection: 'column', gap: 6, maxHeight: 152, overflowY: 'auto', WebkitMaskImage: sortedRides.length > 2 ? 'linear-gradient(180deg, #000 84%, transparent)' : 'none' }}>
              {sortedRides.map(r => {
                const st = r.status || 'accepted';
                const stColor = st === 'pending' ? T.gold : st === 'declined' ? '#FF6B6B' : T.driving;
                const stLabel = st === 'pending' ? `Awaiting ${r.owner}` : st === 'declined' ? `${r.owner} declined` : `Confirmed · ${r.owner}’s ${r.vehicle}`;
                return (
                <div key={r.id} style={{
                  display: 'flex', alignItems: 'center', gap: 10, padding: '8px 10px',
                  borderRadius: 12, background: 'rgba(201,168,76,0.10)', border: `0.5px solid ${T.gold}44`, flexShrink: 0,
                }}>
                  <span style={{ position: 'relative', width: 30, height: 30, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                    {st === 'pending' && <span className="mrt-ready-dot" style={{ position: 'absolute', inset: 0, borderRadius: 9, border: `1.5px solid ${stColor}` }}/>}
                    <span style={{ width: 30, height: 30, borderRadius: 9, background: `${stColor}26`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                      <SFIcon name="calendar" size={14} color={stColor}/>
                    </span>
                  </span>
                  <button onClick={() => viewScheduled(r)} style={{ flex: 1, minWidth: 0, background: 'transparent', border: 'none', cursor: 'pointer', textAlign: 'left', padding: 0, WebkitTapHighlightColor: 'transparent' }}>
                    <div style={{ display: 'flex', alignItems: 'baseline', gap: 7 }}>
                      <span style={{ fontSize: 14, color: T.text, fontWeight: 600, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', flexShrink: 1, minWidth: 0 }}>{r.dest?.label || 'Scheduled ride'}</span>
                      <span style={{ fontSize: 12, color: T.gold, fontWeight: 600, whiteSpace: 'nowrap', flexShrink: 0 }}>{r.schedule.day} {r.schedule.time}</span>
                    </div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 5, marginTop: 2 }}>
                      {st !== 'pending' && <span style={{ width: 5, height: 5, borderRadius: 3, background: stColor, flexShrink: 0 }}/>}
                      <span style={{ fontSize: 11.5, color: stColor, fontWeight: st === 'accepted' ? 400 : 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{stLabel}</span>
                    </div>
                  </button>
                  <button onClick={() => setConfirmCancel(r)} aria-label="Cancel ride" style={{ width: 24, height: 24, borderRadius: 12, background: 'rgba(255,255,255,0.06)', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, WebkitTapHighlightColor: 'transparent' }}>
                    <SFIcon name="xmark" size={9} color={T.textMuted} weight={2}/>
                  </button>
                </div>
                );
              })}
            </div>
          </div>
        )}

        {/* Search + saved + recent — hidden while a ride is active (a new ride
           can't be requested until the current one ends). */}
        {!reqActive && (<>
        <button onClick={() => setPhase('search')} className="mrt-search-glow" style={{
          display: 'flex', alignItems: 'center', gap: 11, width: '100%',
          borderRadius: 14, padding: '15px 16px',
          marginBottom: 14,
          cursor: 'text', textAlign: 'left',
          WebkitTapHighlightColor: 'transparent',
          background: 'rgba(255,255,255,0.025)',
          border: 'none',
        }}>
          <SFIcon name="magnifyingglass" size={16} color={T.gold}/>
          <span style={{ flex: 1, fontSize: 16, color: T.textSec, fontFamily: T.font, letterSpacing: -0.2, fontWeight: 400, overflow: 'hidden' }}>
            <RotatingText items={placeholders}/>
          </span>
        </button>

        {/* Quick saved places — one tap to a route */}
        <div style={{ display: 'flex', gap: 8, marginBottom: 18 }}>
          {[
            { label: 'Home', sub: '221 Folsom St, San Francisco', icon: 'house.fill', miles: 4.2, mins: 18 },
            { label: 'Work', sub: '88 Marina Blvd, San Francisco', icon: 'briefcase.fill', miles: 5.1, mins: 22 },
          ].map((p) => (
            <button key={p.label} onClick={() => { setRequestDest(p); setPinReturn('review'); setPhase('pinDrop'); }} style={{
              flex: 1, display: 'flex', alignItems: 'center', gap: 9, padding: '11px 13px',
              borderRadius: 13, cursor: 'pointer', textAlign: 'left',
              background: 'rgba(255,255,255,0.04)', border: `0.5px solid ${T.border}`,
              WebkitTapHighlightColor: 'transparent', minWidth: 0,
            }}>
              <SFIcon name={p.icon} size={14} color={T.gold}/>
              <span style={{ fontSize: 14.5, color: T.text, fontWeight: 500, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.label}</span>
            </button>
          ))}
        </div>
        </>)}
      </ExpandingRequestSheet>

      {/* Cancel-ride confirmation */}
      {confirmCancel && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 70, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 28 }}>
          <div onClick={() => setConfirmCancel(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .2s ease-out both' }}/>
          <div style={{ position: 'relative', width: '100%', maxWidth: 300, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, boxShadow: '0 20px 60px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .28s cubic-bezier(.32,.72,0,1) both', textAlign: 'center' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="calendar" size={20} color="#FF6B6B"/>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Cancel this ride?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>
              <span style={{ color: T.text, fontWeight: 600 }}>{confirmCancel.dest?.label}</span> on {confirmCancel.schedule.day} {confirmCancel.schedule.time} with {confirmCancel.owner}’s {confirmCancel.vehicle} will be removed.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <button onClick={() => { cancelScheduled(confirmCancel.id); setConfirmCancel(null); }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: 'none', cursor: 'pointer',
                background: 'rgba(255,59,48,0.16)', color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                WebkitTapHighlightColor: 'transparent',
              }}>Cancel ride</button>
              <button onClick={() => setConfirmCancel(null)} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: T.text, fontFamily: T.font, fontSize: 15, fontWeight: 500,
                WebkitTapHighlightColor: 'transparent',
              }}>Keep it</button>
            </div>
          </div>
        </div>
      )}

      {/* Nav stays visible on the live map and during active tracking (the
          request action is complete); hidden only while booking/pending. */}
      {(phase === 'idle' || (phase === 'tracking' && trackProgress < 0.999)) && <BottomNav current={nav} onChange={setNav} tabs={SHARED_TABS}/>}
    </div>
  );
}

Object.assign(window, {
  SignInScreen, EmptyScreen, HomeScreen,
  DrivesScreen, DriveSummaryScreen,
  InvitesScreen, SettingsScreen,
  SharedViewerScreen,
  VEHICLES, DRIVES, STOPS_SAMPLE, buildSampleRoute,
});
