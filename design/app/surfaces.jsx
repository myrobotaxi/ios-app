// MyRoboTaxi · Native iOS surfaces canvas
// Shows widgets (Home + Lock Screen + StandBy + inline), Dynamic Island
// states, and Live Activity Lock Screen presentations side-by-side.

const { useState: sS, useMemo: sM } = React;

// ─────────────────────────────────────────────────────────────
// Wallpaper backgrounds — Lock Screen mocks
// ─────────────────────────────────────────────────────────────
function LockWallpaper({ children, width = 360, height = 720 }) {
  return (
    <div style={{
      width, height, borderRadius: 44, overflow: 'hidden', position: 'relative',
      background: 'radial-gradient(ellipse at 30% 30%, #2a1d3e, #0a0612 60%), linear-gradient(180deg, #0c0814, #06040c)',
      boxShadow: '0 30px 60px rgba(0,0,0,0.5), 0 0 0 1px rgba(255,255,255,0.04)',
      fontFamily: T.font, color: T.text,
    }}>
      <div style={{ position: 'absolute', top: 70, left: 0, right: 0, textAlign: 'center', fontFamily: T.font }}>
        <div style={{ fontSize: 14, color: 'rgba(255,255,255,0.7)', fontWeight: 400 }}>Monday, May 11</div>
        <div style={{ fontSize: 88, fontWeight: 200, lineHeight: 1, marginTop: 4, letterSpacing: -3, color: '#fff' }}>9:41</div>
      </div>
      {children}
    </div>
  );
}

function HomeWallpaper({ children, width = 360, height = 720 }) {
  return (
    <div style={{
      width, height, borderRadius: 44, overflow: 'hidden', position: 'relative',
      background: 'radial-gradient(ellipse at 70% 80%, #1e2434, #050608 70%), linear-gradient(180deg, #0a0b12, #04060a)',
      boxShadow: '0 30px 60px rgba(0,0,0,0.5), 0 0 0 1px rgba(255,255,255,0.04)',
      fontFamily: T.font, color: T.text,
    }}>
      {children}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Widgets
// ─────────────────────────────────────────────────────────────
function WidgetShell({ size, children, label }) {
  const dims = {
    small:    { w: 158, h: 158, r: 22 },
    medium:   { w: 338, h: 158, r: 22 },
    large:    { w: 338, h: 354, r: 22 },
    circular: { w: 72,  h: 72,  r: 36, lockscreen: true },
    rect:     { w: 158, h: 72,  r: 18, lockscreen: true },
    inline:   { w: 240, h: 22,  r: 8,  lockscreen: true, inline: true },
  };
  const d = dims[size];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10 }}>
      <div style={{
        width: d.w, height: d.h, borderRadius: d.r,
        background: d.lockscreen ? 'rgba(255,255,255,0.18)' : T.surface,
        backdropFilter: d.lockscreen ? 'blur(20px)' : undefined,
        WebkitBackdropFilter: d.lockscreen ? 'blur(20px)' : undefined,
        border: d.lockscreen ? '0.5px solid rgba(255,255,255,0.18)' : `0.5px solid ${T.border}`,
        overflow: 'hidden', position: 'relative', color: T.text,
        boxShadow: d.lockscreen ? 'none' : '0 10px 26px rgba(0,0,0,0.4)',
      }}>{children}</div>
      <div style={{ fontSize: 10, color: T.textMuted, letterSpacing: 1, textTransform: 'uppercase', fontWeight: 500 }}>{label}</div>
    </div>
  );
}

function WidgetHomeSmall({ vehicle = 'Cybercab', status = 'parked', battery = 68 }) {
  return (
    <div style={{ padding: 14, height: '100%', display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 6 }}>
        <HexLogo size={14}/>
        <span style={{ fontSize: 10, color: T.textMuted, letterSpacing: 0.5, fontWeight: 500, textTransform: 'uppercase' }}>MyRoboTaxi</span>
      </div>
      <div style={{ fontSize: 15, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>{vehicle}</div>
      <div style={{ marginTop: 4 }}><StatusBadge status={status} size={11}/></div>
      <div style={{ flex: 1 }}/>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 4, marginBottom: 4 }}>
        <span style={{ fontFamily: T.fontNum, fontSize: 22, fontWeight: 300, color: T.text, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.6, lineHeight: 1 }}>{battery}</span>
        <span style={{ fontSize: 11, color: T.textMuted }}>%</span>
      </div>
      <BatteryBar pct={battery} height={3}/>
      <div style={{ fontSize: 9, color: T.textMuted, marginTop: 8, letterSpacing: 0.4 }}>Updated 12s ago</div>
    </div>
  );
}

function WidgetHomeMedium({ vehicle = 'Cybercab', status = 'driving', battery = 68, progress = 0.42, eta = 51 }) {
  const route = sM(() => buildSampleRoute(), []);
  return (
    <div style={{ display: 'flex', height: '100%' }}>
      <div style={{ flex: 1, padding: 14, display: 'flex', flexDirection: 'column' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 6 }}>
          <HexLogo size={14}/>
          <span style={{ fontSize: 10, color: T.textMuted, letterSpacing: 0.5, fontWeight: 500, textTransform: 'uppercase' }}>MyRoboTaxi</span>
        </div>
        <div style={{ fontSize: 14, fontWeight: 600, color: T.text }}>{vehicle}</div>
        <div style={{ marginTop: 4 }}><StatusBadge status={status} size={10}/></div>
        <div style={{ flex: 1 }}/>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6, fontFamily: T.fontNum }}>
          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 9, color: T.textMuted, letterSpacing: 0.7, fontWeight: 500 }}>ETA</span>
            <span style={{ fontSize: 12, fontWeight: 500, color: T.gold, fontVariantNumeric: 'tabular-nums' }}>{eta} min</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
            <span style={{ fontSize: 9, color: T.textMuted, letterSpacing: 0.7, fontWeight: 500 }}>BATTERY</span>
            <span style={{ fontSize: 12, fontWeight: 500, color: T.text, fontVariantNumeric: 'tabular-nums' }}>{battery}%</span>
          </div>
        </div>
      </div>
      <div style={{ width: 148, position: 'relative' }}>
        <MapBackground width={148} height={158} seed={42}/>
        <svg width="148" height="158" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
          <RouteLine path={route} progress={progress} width={6} glow={false}/>
          <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={16}/>
        </svg>
        {/* Vehicle marker dot — small */}
        <div style={{ position: 'absolute', left: 55, top: 78, width: 8, height: 8, marginLeft: -4, marginTop: -4, borderRadius: 4, background: T.gold, border: '1px solid #fff', boxShadow: `0 0 6px ${T.gold}` }}/>
      </div>
    </div>
  );
}

function WidgetHomeLarge({ vehicle = 'Cybercab', status = 'driving', battery = 68, progress = 0.42, eta = 51, speed = 64 }) {
  const route = sM(() => buildSampleRoute(), []);
  return (
    <div style={{ padding: 14, height: '100%', display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <HexLogo size={14}/>
        <span style={{ fontSize: 10, color: T.textMuted, letterSpacing: 0.5, fontWeight: 500, textTransform: 'uppercase' }}>MyRoboTaxi</span>
        <span style={{ flex: 1 }}/>
        <StatusBadge status={status} size={10}/>
      </div>
      <div>
        <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3 }}>{vehicle}</div>
        <div style={{ fontSize: 11, color: T.gold, marginTop: 2 }}>→ Pescadero · Duarte's Tavern</div>
      </div>
      <div style={{ height: 132, borderRadius: 12, overflow: 'hidden', position: 'relative' }}>
        <MapBackground width={310} height={132} seed={42}/>
        <svg width="310" height="132" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
          <RouteLine path={route} progress={progress} width={5} glow={false}/>
          <EndpointDot x={route[0][0]} y={route[0][1]} color={T.driving} size={12}/>
          <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={14}/>
        </svg>
      </div>
      <TripProgressBar progress={progress} stops={STOPS_SAMPLE} compact/>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 6 }}>
        {[['ETA', eta, 'min', true], ['Speed', speed, 'mph'], ['Battery', battery, '%'], ['FSD', 38.2, 'mi', true]].map(([l, v, u, gold], i) => (
          <div key={i}>
            <div style={{ fontSize: 8, color: T.textMuted, letterSpacing: 0.8, fontWeight: 500, textTransform: 'uppercase' }}>{l}</div>
            <div style={{ fontFamily: T.fontNum, fontSize: 14, fontWeight: 400, color: gold ? T.gold : T.text, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3, marginTop: 2 }}>
              {v}<span style={{ fontSize: 9, color: T.textMuted, marginLeft: 2 }}>{u}</span>
            </div>
          </div>
        ))}
      </div>
      <div style={{ fontSize: 9, color: T.textMuted, marginTop: 'auto', letterSpacing: 0.4 }}>Live · updated just now</div>
    </div>
  );
}

function WidgetLockCircular({ pct = 68 }) {
  const R = 30, C = 2 * Math.PI * R;
  const off = C * (1 - pct / 100);
  const color = pct > 50 ? T.batHigh : pct > 20 ? T.batMid : T.batLow;
  return (
    <div style={{ position: 'relative', width: 72, height: 72, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <svg width="72" height="72" style={{ position: 'absolute', inset: 0, transform: 'rotate(-90deg)' }}>
        <circle cx="36" cy="36" r={R} stroke="rgba(255,255,255,0.18)" strokeWidth="4" fill="none"/>
        <circle cx="36" cy="36" r={R} stroke={color} strokeWidth="4" fill="none" strokeLinecap="round"
          strokeDasharray={C} strokeDashoffset={off} style={{ filter: `drop-shadow(0 0 4px ${color}66)` }}/>
      </svg>
      <div style={{ textAlign: 'center', position: 'relative' }}>
        <div style={{ fontSize: 8, color: 'rgba(255,255,255,0.7)', fontWeight: 600, letterSpacing: 0.4, marginBottom: -1 }}>BATT</div>
        <div style={{ fontFamily: T.fontNum, fontSize: 17, fontWeight: 600, color: T.text, lineHeight: 1, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3 }}>{pct}<span style={{ fontSize: 9, fontWeight: 400 }}>%</span></div>
      </div>
    </div>
  );
}

function WidgetLockRect({ status = 'driving', eta = 51, battery = 68 }) {
  const showEta = status === 'driving';
  return (
    <div style={{ padding: '8px 12px', height: '100%', display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 4, color: T.text }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span style={{ width: 5, height: 5, borderRadius: 3, background: T.gold, boxShadow: `0 0 6px ${T.gold}` }}/>
        <span style={{ fontSize: 9, color: 'rgba(255,255,255,0.7)', fontWeight: 600, letterSpacing: 0.6, textTransform: 'uppercase' }}>{status === 'driving' ? 'En route' : status === 'charging' ? 'Charging' : 'Parked'}</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
        <span style={{ fontFamily: T.fontNum, fontSize: 22, fontWeight: 500, color: T.text, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.5, lineHeight: 1 }}>{showEta ? eta : battery}</span>
        <span style={{ fontSize: 11, color: 'rgba(255,255,255,0.7)' }}>{showEta ? 'min to Pescadero' : '% · Embarcadero'}</span>
      </div>
    </div>
  );
}

function WidgetLockInline({ status = 'driving', eta = 51 }) {
  return (
    <div style={{ height: 22, padding: '0 6px', display: 'flex', alignItems: 'center', gap: 6 }}>
      <span style={{ width: 5, height: 5, borderRadius: 3, background: T.gold, boxShadow: `0 0 4px ${T.gold}` }}/>
      <span style={{ fontFamily: T.font, fontSize: 13, fontWeight: 500, color: '#fff', letterSpacing: -0.1 }}>
        Cybercab · {status === 'driving' ? `${eta} min to Pescadero` : 'Parked at Embarcadero'}
      </span>
    </div>
  );
}

function WidgetStandBy({ progress = 0.42, eta = 51, battery = 68 }) {
  const route = sM(() => buildSampleRoute(), []);
  // StandBy = full-bleed map, gold accents only, optimized for AOD.
  return (
    <div style={{ width: 484, height: 272, borderRadius: 18, overflow: 'hidden', position: 'relative', background: '#000', boxShadow: '0 20px 50px rgba(0,0,0,0.7)' }}>
      <MapBackground width={484} height={272} seed={42}/>
      <svg width="484" height="272" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
        <RouteLine path={route} progress={progress} width={5} glow/>
        <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={16}/>
      </svg>
      {/* Overlay info, bottom-left, AOD-safe (gold only) */}
      <div style={{ position: 'absolute', left: 18, bottom: 16, display: 'flex', flexDirection: 'column', gap: 4 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 7, height: 7, borderRadius: 4, background: T.gold, boxShadow: `0 0 8px ${T.gold}` }}/>
          <span style={{ fontFamily: T.font, fontSize: 11, fontWeight: 600, color: T.gold, letterSpacing: 1, textTransform: 'uppercase' }}>Cybercab · En route</span>
        </div>
        <div style={{ fontFamily: T.fontNum, fontSize: 38, fontWeight: 300, color: T.gold, fontVariantNumeric: 'tabular-nums', letterSpacing: -1, lineHeight: 1 }}>
          {eta}<span style={{ fontSize: 16, fontWeight: 400, marginLeft: 4 }}>min</span>
        </div>
        <div style={{ fontFamily: T.font, fontSize: 12, color: T.goldLight, opacity: 0.7, marginTop: 2 }}>to Pescadero · {battery}% battery</div>
      </div>
      <div style={{ position: 'absolute', top: 18, right: 18, fontFamily: T.font, fontSize: 11, color: 'rgba(201,168,76,0.5)', fontWeight: 500, letterSpacing: 1 }}>STANDBY</div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Live Activity — Lock Screen card (full, compact/stale, banner)
// Sized to fit on a Lock Screen wallpaper, 14pt corner radius.
// ─────────────────────────────────────────────────────────────
function LiveActivityCard({ kind = 'full', vehicle = 'Cybercab', progress = 0.42, battery = 68, speed = 64, eta = 51, width = 332 }) {
  const stale = kind === 'stale';
  const dim = stale ? 0.5 : 1;
  return (
    <div style={{
      width, borderRadius: 20, padding: '12px 14px',
      background: 'rgba(20,20,22,0.62)', backdropFilter: 'blur(28px) saturate(180%)',
      WebkitBackdropFilter: 'blur(28px) saturate(180%)',
      border: '0.5px solid rgba(255,255,255,0.18)', color: T.text, fontFamily: T.font,
      opacity: dim,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
        <HexLogo size={18}/>
        <span style={{ fontSize: 10, color: 'rgba(255,255,255,0.6)', fontWeight: 500, letterSpacing: 0.6, textTransform: 'uppercase', flex: 1 }}>MyRoboTaxi · {stale ? 'Updated 4 min ago' : 'Now'}</span>
        <StatusBadge status="driving" size={10}/>
      </div>
      {kind === 'banner' ? (
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{ width: 36, height: 36, borderRadius: 18, background: 'rgba(201,168,76,0.18)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <SFIcon name="car.fill" size={20} color={T.gold} fill/>
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 14, fontWeight: 600 }}>{vehicle} arrived</div>
            <div style={{ fontSize: 11, color: 'rgba(255,255,255,0.65)', marginTop: 2 }}>Pescadero · 1h 27m · {battery}% battery</div>
          </div>
          <SFIcon name="chevron.right" size={14} color="rgba(255,255,255,0.4)"/>
        </div>
      ) : (
        <>
          <div style={{ fontSize: 14, fontWeight: 500, marginBottom: 10 }}>
            {vehicle} <span style={{ color: 'rgba(255,255,255,0.5)', margin: '0 6px' }}>→</span> <span style={{ color: T.gold }}>Pescadero</span>
          </div>
          <TripProgressBar progress={progress} stops={STOPS_SAMPLE} compact/>
          <div style={{ display: 'flex', gap: 14, marginTop: 10, fontFamily: T.fontNum }}>
            {[['ETA', eta, 'min'], ['Speed', stale ? '—' : speed, 'mph'], ['Battery', battery, '%']].map(([l, v, u], i) => (
              <div key={i} style={{ flex: 1 }}>
                <div style={{ fontSize: 9, color: 'rgba(255,255,255,0.5)', letterSpacing: 0.7, fontWeight: 500, textTransform: 'uppercase' }}>{l}</div>
                <div style={{ fontSize: 14, fontWeight: 500, marginTop: 2, fontVariantNumeric: 'tabular-nums' }}>{v}<span style={{ color: 'rgba(255,255,255,0.5)', fontSize: 11, marginLeft: 2 }}>{u}</span></div>
              </div>
            ))}
          </div>
          {stale && (
            <div style={{ marginTop: 8, padding: '6px 10px', background: 'rgba(255,255,255,0.06)', borderRadius: 8, fontSize: 10, color: 'rgba(255,255,255,0.55)', letterSpacing: 0.3 }}>
              Stale · last update before Pacifica tunnel
            </div>
          )}
        </>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Dynamic Island showcase — render inside a mini bezel for context
// ─────────────────────────────────────────────────────────────
function DIShowcase({ state, label, longPress = false }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12 }}>
      <div style={{
        width: 240, height: state === 'expanded' ? 200 : (longPress ? 320 : 90),
        borderRadius: 36, padding: 8, boxSizing: 'border-box',
        background: 'linear-gradient(155deg, #2a2a2c, #16161a)',
        boxShadow: '0 20px 50px rgba(0,0,0,0.55), 0 0 0 1.2px rgba(255,255,255,0.05)',
        position: 'relative',
      }}>
        <div style={{ width: '100%', height: '100%', background: '#000', borderRadius: 30, position: 'relative', overflow: 'visible' }}>
          {/* Mini status bar */}
          <div style={{ position: 'absolute', top: 8, left: 16, right: 16, display: 'flex', justifyContent: 'space-between', fontFamily: T.font, fontSize: 9, color: '#fff', fontWeight: 600, pointerEvents: 'none' }}>
            <span>9:41</span><span style={{ opacity: 0.7 }}>● ● ●</span>
          </div>
          <DynamicIsland state={state} vehicle="Cybercab" status="driving" eta={51} battery={68} speed={64} progress={0.42}/>
          {longPress && (
            <div style={{ position: 'absolute', top: 60, left: 16, right: 16, background: 'rgba(30,30,32,0.92)', backdropFilter: 'blur(20px)', borderRadius: 16, padding: 8, border: '0.5px solid rgba(255,255,255,0.08)' }}>
              {[
                ['map.fill', 'Open Map', true],
                ['location.fill', 'Center on Vehicle'],
                ['square.and.arrow.up', 'Share Live Location'],
                ['xmark', 'End Live Activity'],
              ].map(([icon, label, gold], i, arr) => (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '8px 10px', borderTop: i === 0 ? 'none' : '0.5px solid rgba(255,255,255,0.06)' }}>
                  <SFIcon name={icon} size={16} color={gold ? T.gold : '#fff'}/>
                  <span style={{ fontFamily: T.font, fontSize: 13, color: gold ? T.gold : '#fff', fontWeight: gold ? 500 : 400 }}>{label}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
      <div style={{ fontFamily: T.font, fontSize: 11, color: T.textMuted, letterSpacing: 1, textTransform: 'uppercase', fontWeight: 500 }}>{label}</div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Token map row
// ─────────────────────────────────────────────────────────────
function TokenSwatch({ name, hex, swift, usage }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '10px 14px', background: T.surface, borderRadius: 12, border: `0.5px solid ${T.border}` }}>
      <div style={{ width: 36, height: 36, borderRadius: 8, background: hex, border: '0.5px solid rgba(255,255,255,0.1)' }}/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 12, color: T.text, fontWeight: 500 }}>{name}</div>
        <div style={{ fontSize: 11, color: T.textMuted, fontFamily: 'ui-monospace, SF Mono, monospace', marginTop: 2 }}>{hex} · {swift}</div>
        {usage && <div style={{ fontSize: 10, color: T.textSec, marginTop: 4, lineHeight: 1.4 }}>{usage}</div>}
      </div>
    </div>
  );
}

const TOKENS = [
  { name: 'bg.primary',     hex: '#0A0A0A', swift: 'Color.mrtBackground',      usage: 'Page background, app shell. Asset Catalog: dark-only colorset.' },
  { name: 'bg.surface',     hex: '#1A1A1A', swift: 'Color.mrtSurface',         usage: 'Cards, input fields. .background(.mrtSurface) on every Card.' },
  { name: 'bg.elevated',    hex: '#2A2A2A', swift: 'Color.mrtElevated',        usage: 'Toggle tracks (off), TripProgressBar track.' },
  { name: 'text.primary',   hex: '#FFFFFF', swift: 'Color.mrtText',            usage: '.foregroundStyle(.mrtText) for headlines + body.' },
  { name: 'text.secondary', hex: '#A0A0A0', swift: 'Color.mrtTextSecondary',   usage: 'Subtitles, body text, descriptions.' },
  { name: 'text.muted',     hex: '#6B6B6B', swift: 'Color.mrtTextMuted',       usage: 'Labels, timestamps, offline status.' },
  { name: 'gold',           hex: '#C9A84C', swift: 'Color.mrtGold',            usage: 'Sacred — CTAs, active nav, vehicle marker, route, brand.' },
  { name: 'gold.light',     hex: '#D4C88A', swift: 'Color.mrtGoldLight',       usage: 'Pressed/hover. Use on .hoverEffect(.highlight).' },
  { name: 'gold.dark',      hex: '#A0862E', swift: 'Color.mrtGoldDark',        usage: 'Hex gradient stops, deep ring shadow.' },
  { name: 'status.driving', hex: '#30D158', swift: 'Color.mrtDriving',         usage: 'StatusBadge dot, start-point map marker, online viewer.' },
  { name: 'status.parked',  hex: '#3B82F6', swift: 'Color.mrtParked',          usage: 'StatusBadge dot when vehicle stationary.' },
  { name: 'status.charging',hex: '#FFD60A', swift: 'Color.mrtCharging',        usage: 'StatusBadge + BatteryBar when AC/DC plugged in.' },
  { name: 'status.offline', hex: '#6B6B6B', swift: 'Color.mrtOffline',         usage: 'Vehicle unreachable; matches text.muted by design.' },
];

const TYPE_TOKENS = [
  { web: 'Screen Title · 24 / 600',  ios: '.title2.weight(.semibold)',      tracking: '-0.5pt', notes: 'Page headings; supports Dynamic Type.' },
  { web: 'Section Title · 18 / 600', ios: '.headline',                      tracking: '-0.3pt', notes: 'Vehicle name, card headings.' },
  { web: 'Body · 14–15 / 300–400',   ios: '.subheadline / .body',           tracking: '0',      notes: 'SF Pro Display weight .regular for 14, .light for marketing.' },
  { web: 'Label · 12 / 500 UPPER',   ios: '.caption.weight(.medium)',       tracking: '+1.2pt', notes: '.textCase(.uppercase) + .kerning(1.2).' },
  { web: 'Micro · 10 / 500',         ios: '.caption2.weight(.medium)',      tracking: '+0.2pt', notes: 'Tab labels — falls back to SF Compact at small sizes.' },
  { web: 'Hero Number · 36–40 / 300',ios: '.largeTitle.weight(.light)',     tracking: '-1pt',   notes: '.monospacedDigit() ALWAYS for live values.' },
];

// ─────────────────────────────────────────────────────────────
// Page layout
// ─────────────────────────────────────────────────────────────
function SurfacesApp() {
  return (
    <DesignCanvas>
      <DCSection id="di" title="Dynamic Island" subtitle="iPhone 14 Pro and newer · live during driving">
        <DCArtboard id="di-minimal" label="Minimal" width={310} height={300}>
          <Frame><DIShowcase state="minimal" label="Minimal · gold dot only"/></Frame>
        </DCArtboard>
        <DCArtboard id="di-compact" label="Compact" width={310} height={300}>
          <Frame><DIShowcase state="compact" label="Compact · status ring + ETA"/></Frame>
        </DCArtboard>
        <DCArtboard id="di-expanded" label="Expanded" width={310} height={300}>
          <Frame><DIShowcase state="expanded" label="Expanded · mini map + stats"/></Frame>
        </DCArtboard>
        <DCArtboard id="di-longpress" label="Long-press menu" width={310} height={420}>
          <Frame><DIShowcase state="compact" longPress label="Long-press · deep-link menu"/></Frame>
        </DCArtboard>
      </DCSection>

      <DCSection id="la" title="Live Activity" subtitle="ActivityKit · iOS 16.1+ · ended on arrival">
        <DCArtboard id="la-full" label="Lock Screen · full" width={420} height={520}>
          <Frame>
            <LockWallpaper width={360} height={460}>
              <div style={{ position: 'absolute', top: 250, left: 14, right: 14 }}>
                <LiveActivityCard kind="full" width={332}/>
              </div>
            </LockWallpaper>
          </Frame>
        </DCArtboard>
        <DCArtboard id="la-stale" label="Stale state" width={420} height={520}>
          <Frame>
            <LockWallpaper width={360} height={460}>
              <div style={{ position: 'absolute', top: 250, left: 14, right: 14 }}>
                <LiveActivityCard kind="stale" width={332}/>
              </div>
            </LockWallpaper>
          </Frame>
        </DCArtboard>
        <DCArtboard id="la-banner" label="Banner · arrival alert" width={420} height={520}>
          <Frame>
            <LockWallpaper width={360} height={460}>
              <div style={{ position: 'absolute', top: 250, left: 14, right: 14 }}>
                <LiveActivityCard kind="banner" width={332}/>
              </div>
            </LockWallpaper>
          </Frame>
        </DCArtboard>
      </DCSection>

      <DCSection id="home-widgets" title="Home Screen Widgets" subtitle="WidgetKit · iOS 17+ · AppIntentConfiguration for multi-vehicle">
        <DCArtboard id="w-small" label="Small" width={220} height={240}>
          <Frame><WidgetShell size="small" label="Small · 158pt"><WidgetHomeSmall/></WidgetShell></Frame>
        </DCArtboard>
        <DCArtboard id="w-medium" label="Medium" width={400} height={240}>
          <Frame><WidgetShell size="medium" label="Medium · 338pt"><WidgetHomeMedium/></WidgetShell></Frame>
        </DCArtboard>
        <DCArtboard id="w-large" label="Large" width={400} height={440}>
          <Frame><WidgetShell size="large" label="Large · 338pt"><WidgetHomeLarge/></WidgetShell></Frame>
        </DCArtboard>
      </DCSection>

      <DCSection id="lock-widgets" title="Lock Screen Widgets" subtitle="Tinted-glass over wallpaper">
        <DCArtboard id="w-lock-rect" label="Rectangular" width={420} height={460}>
          <Frame>
            <LockWallpaper width={360} height={400}>
              <div style={{ position: 'absolute', top: 220, left: 22, display: 'flex', gap: 14 }}>
                <WidgetShell size="circular" label="Circular"><WidgetLockCircular pct={68}/></WidgetShell>
                <WidgetShell size="rect" label="Rectangular"><WidgetLockRect/></WidgetShell>
              </div>
              <div style={{ position: 'absolute', top: 180, left: 0, right: 0, display: 'flex', justifyContent: 'center' }}>
                <WidgetShell size="inline" label="Inline"><WidgetLockInline/></WidgetShell>
              </div>
            </LockWallpaper>
          </Frame>
        </DCArtboard>
        <DCArtboard id="w-standby" label="StandBy" width={540} height={340}>
          <Frame><WidgetStandBy/></Frame>
        </DCArtboard>
      </DCSection>

      <DCSection id="tokens" title="Token map · Web → SwiftUI" subtitle="Asset Catalog: Dark appearance only">
        <DCArtboard id="tokens-color" label="Colors" width={500} height={760}>
          <Frame padding={24}>
            <Label style={{ marginBottom: 16 }}>Color extension</Label>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {TOKENS.map(t => <TokenSwatch key={t.name} {...t}/>)}
            </div>
          </Frame>
        </DCArtboard>
        <DCArtboard id="tokens-type" label="Type" width={520} height={520}>
          <Frame padding={24}>
            <Label style={{ marginBottom: 16 }}>Font extension on SF Pro</Label>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {TYPE_TOKENS.map((t, i) => (
                <div key={i} style={{ padding: 14, background: T.surface, borderRadius: 12, border: `0.5px solid ${T.border}` }}>
                  <div style={{ fontSize: 13, color: T.text, fontWeight: 500 }}>{t.web}</div>
                  <div style={{ fontSize: 11, color: T.gold, fontFamily: 'ui-monospace, SF Mono, monospace', marginTop: 4 }}>{t.ios} · tracking {t.tracking}</div>
                  <div style={{ fontSize: 11, color: T.textSec, marginTop: 4, lineHeight: 1.5 }}>{t.notes}</div>
                </div>
              ))}
            </div>
          </Frame>
        </DCArtboard>
        <DCArtboard id="tokens-spacing" label="Spacing & Radius" width={420} height={520}>
          <Frame padding={24}>
            <Label style={{ marginBottom: 16 }}>Layout constants</Label>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {[
                ['Page horizontal', '24pt', '.padding(.horizontal, 24)'],
                ['Card radius', '16pt', 'RoundedRectangle(cornerRadius: 16)'],
                ['Input/Button radius', '12pt', 'RoundedRectangle(cornerRadius: 12)'],
                ['Bottom sheet radius', '24pt', '.presentationCornerRadius(24)'],
                ['Section gap', '32pt', '.padding(.vertical, 32)'],
                ['Card gap', '12pt', 'VStack(spacing: 12)'],
              ].map(([k, v, code], i) => (
                <div key={i} style={{ padding: 14, background: T.surface, borderRadius: 12, border: `0.5px solid ${T.border}`, display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 10 }}>
                  <div>
                    <div style={{ fontSize: 13, color: T.text, fontWeight: 500 }}>{k}</div>
                    <div style={{ fontSize: 11, color: T.textMuted, fontFamily: 'ui-monospace, SF Mono, monospace', marginTop: 4 }}>{code}</div>
                  </div>
                  <div style={{ fontFamily: T.fontNum, fontSize: 18, fontWeight: 500, color: T.gold, fontVariantNumeric: 'tabular-nums' }}>{v}</div>
                </div>
              ))}
            </div>
          </Frame>
        </DCArtboard>
      </DCSection>

      <DCSection id="decisions" title="Deviations & Open Questions" subtitle="Annotated rationale">
        <DCArtboard id="deviations" label="Where iOS diverges from web" width={520} height={620}>
          <Frame padding={24}>
            <Label style={{ marginBottom: 16 }}>Design decisions</Label>
            {[
              ['Bottom sheet uses `.presentationDetents([.height(260), .medium])`',
                'Native API matches web peek (260pt) and half (≈50vh). Custom gesture only retained for the home indicator-area peek snap on initial load.'],
              ['Inter → SF Pro on iOS',
                'System font is required for Dynamic Type and accessibility scaling. Visual hierarchy preserved via type scale, not literal point sizes.'],
              ['Mapbox GL JS → MapKit',
                'Native, free, and uses the same `MKMapView` overlay APIs we already need for vehicle annotation. Accepts a small fidelity loss on building extrusions.'],
              ['SVG icons → SF Symbols',
                '1:1 mapping for map.fill, clock, person.2, gearshape, bolt.fill, battery.100, location.fill. Custom vector retained only for hex logo and vehicle marker.'],
              ['Swipe vehicle switcher → tap dots',
                'Web spec; preserved on iOS to avoid conflict with `MKMapView` pan gesture.'],
              ['"Sign in with Apple" → AuthenticationServices button',
                'Native button is mandated by App Store review; Google retained as outline-muted to match weight.'],
              ['Share → UIActivityViewController',
                'System share sheet replaces the web custom modal. Universal Link payload is the canonical deep link.'],
            ].map(([title, body], i) => (
              <div key={i} style={{ padding: '14px 0', borderTop: i ? '0.5px solid #1f1f1f' : 'none' }}>
                <div style={{ fontSize: 13, color: T.gold, fontWeight: 500, marginBottom: 6 }}>{title}</div>
                <div style={{ fontSize: 12, color: T.textSec, lineHeight: 1.55 }}>{body}</div>
              </div>
            ))}
          </Frame>
        </DCArtboard>
        <DCArtboard id="open-questions" label="Open questions" width={460} height={620}>
          <Frame padding={24}>
            <Label style={{ marginBottom: 16 }}>Need answers before build</Label>
            {[
              ['Update cadence', 'Live Activity push every 60s during steady driving, 15s in last 5 min before arrival? Background fetches will burn budget.'],
              ['Stale state policy', 'When does `staleDate` flip? Proposal: 4 min without an update.'],
              ['Push token routing', 'Backend ownership — need ActivityKit push channel separate from APNs alerts.'],
              ['Multi-vehicle Siri intent', 'Default vehicle disambiguation: most-recently-active? user-pinned?'],
              ['Widget refresh budget', 'Map snippet widgets need a freshness floor. Acceptable cadence?'],
              ['Apple Watch hook', 'Out of scope for v1 — but should the iOS app already wire up Watch Connectivity stubs?'],
              ['Vehicle marker pulse on AOD', 'StandBy lowers brightness — should pulse animation pause or keep going at reduced intensity?'],
            ].map(([title, body], i) => (
              <div key={i} style={{ padding: '12px 0', borderTop: i ? '0.5px solid #1f1f1f' : 'none' }}>
                <div style={{ fontSize: 13, color: T.text, fontWeight: 500, marginBottom: 4 }}>{title}</div>
                <div style={{ fontSize: 12, color: T.textSec, lineHeight: 1.5 }}>{body}</div>
              </div>
            ))}
          </Frame>
        </DCArtboard>
      </DCSection>

      <DCSection id="links" title="Related" subtitle="Open the interactive prototype">
        <DCArtboard id="link-proto" label="Prototype" width={360} height={200}>
          <Frame padding={28}>
            <Label style={{ marginBottom: 14 }}>Interactive iPhone prototype</Label>
            <div style={{ fontSize: 14, color: T.text, lineHeight: 1.5, marginBottom: 18 }}>
              All 8 screens with Tweaks: vehicle state, trip progress, battery, DI state.
            </div>
            <a href="prototype.html" style={{
              display: 'inline-flex', alignItems: 'center', gap: 8,
              padding: '10px 18px', borderRadius: 12,
              background: T.gold, color: '#1a1408', textDecoration: 'none',
              fontFamily: T.font, fontSize: 14, fontWeight: 600,
            }}>Open prototype →</a>
          </Frame>
        </DCArtboard>
      </DCSection>
    </DesignCanvas>
  );
}

function Frame({ children, padding = 0 }) {
  return (
    <div style={{ width: '100%', height: '100%', background: T.bg, borderRadius: 24, padding, boxSizing: 'border-box', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 14, overflow: 'hidden', color: T.text, fontFamily: T.font }}>
      {children}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<SurfacesApp/>);
