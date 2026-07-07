// iPhone 17 Pro frame with live Dynamic Island. Replaces the simpler
// IOSDevice for the prototype so we can show DI states.
const { useState: usS, useEffect: usE, useMemo: usM } = React;

// ─────────────────────────────────────────────────────────────
// Dynamic Island — compact / expanded / minimal states
// ─────────────────────────────────────────────────────────────
function DynamicIsland({ state = 'minimal', expandedStyle = 'flighty', vehicle, status, eta, battery, speed, progress, onLongPress }) {
  // Sizes — iPhone 17 Pro has same DI as 14 Pro: 126×37 minimum
  const expanded = state === 'expanded';
  const compact = state === 'compact';
  const expandedH = expandedStyle === 'flighty' ? 128 : expandedStyle === 'uber' ? 116 : 158;
  const w = expanded ? 374 : 126;
  const h = expanded ? expandedH : 37;
  const route = usM(() => buildSampleRoute(), []);

  const ringColor = status === 'driving' ? T.driving : status === 'charging' ? T.charging : T.parked;

  return (
    <div onContextMenu={(e) => { e.preventDefault(); onLongPress && onLongPress(); }}
      style={{
      position: 'absolute', top: 11, left: '50%', transform: 'translateX(-50%)',
      width: w, height: h, borderRadius: expanded ? 44 : 24,
      background: '#000', zIndex: 50, overflow: 'hidden',
      transition: 'width .35s cubic-bezier(.4,0,.2,1), height .35s cubic-bezier(.4,0,.2,1), border-radius .35s',
      cursor: 'pointer',
      boxShadow: expanded ? '0 12px 32px rgba(0,0,0,0.6)' : 'none',
    }}>
      {state === 'minimal' && (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'flex-end', paddingRight: 14 }}>
          <span style={{ width: 8, height: 8, borderRadius: 4, background: T.gold, boxShadow: `0 0 8px ${T.goldGlow6}` }}/>
        </div>
      )}
      {compact && (
        <>
          {/* Leading: gold dot + status ring */}
          <div style={{ position: 'absolute', left: 14, top: '50%', transform: 'translateY(-50%)', width: 18, height: 18, borderRadius: 9, border: `1.5px solid ${ringColor}`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <span style={{ width: 8, height: 8, borderRadius: 4, background: T.gold, boxShadow: `0 0 6px ${T.gold}` }}/>
          </div>
          {/* Trailing: ETA or battery, tabular */}
          <div style={{ position: 'absolute', right: 14, top: '50%', transform: 'translateY(-50%)', fontFamily: T.font, fontVariantNumeric: 'tabular-nums', fontSize: 13, fontWeight: 600, color: status === 'driving' ? T.gold : T.text, letterSpacing: -0.2 }}>
            {status === 'driving' ? `${eta} min` : `${Math.round(battery)}%`}
          </div>
        </>
      )}
      {expanded && expandedStyle === 'flighty' && (
        <div style={{ position: 'absolute', inset: 0, padding: '36px 22px 16px' }}>
          {/* Status header */}
          <div style={{ position: 'absolute', top: 11, left: 22, right: 22, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
              <span style={{ width: 7, height: 7, borderRadius: 4, background: T.gold, boxShadow: `0 0 6px ${T.gold}` }}/>
              <span style={{ fontFamily: T.font, fontSize: 12, fontWeight: 600, color: T.text, letterSpacing: -0.1 }}>{vehicle}</span>
            </div>
            <span style={{ fontFamily: T.font, fontSize: 9.5, color: T.driving, fontWeight: 600, letterSpacing: 0.7 }}>EN ROUTE</span>
          </div>
          {/* Stats row — big ETA + secondary tabular pair */}
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 14 }}>
            <div>
              <div style={{ fontFamily: T.fontNum, fontSize: 30, fontWeight: 300, color: T.gold, lineHeight: 1, fontVariantNumeric: 'tabular-nums', letterSpacing: -1 }}>
                {eta}<span style={{ fontSize: 13, fontWeight: 400, marginLeft: 3, opacity: 0.75 }}>min</span>
              </div>
              <div style={{ fontSize: 8.5, color: T.textMuted, letterSpacing: 1, fontWeight: 600, marginTop: 4 }}>ETA</div>
            </div>
            <div style={{ width: 1, height: 28, background: 'rgba(255,255,255,0.10)' }}/>
            <div>
              <div style={{ fontFamily: T.fontNum, fontSize: 17, fontWeight: 400, color: T.text, lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>
                {speed}<span style={{ fontSize: 10, color: T.textMuted, marginLeft: 2 }}>mph</span>
              </div>
              <div style={{ fontSize: 8.5, color: T.textMuted, letterSpacing: 1, fontWeight: 600, marginTop: 4 }}>SPEED</div>
            </div>
            <div style={{ width: 1, height: 28, background: 'rgba(255,255,255,0.10)' }}/>
            <div>
              <div style={{ fontFamily: T.fontNum, fontSize: 17, fontWeight: 400, color: T.text, lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>
                {Math.round(battery)}<span style={{ fontSize: 10, color: T.textMuted, marginLeft: 2 }}>%</span>
              </div>
              <div style={{ fontSize: 8.5, color: T.textMuted, letterSpacing: 1, fontWeight: 600, marginTop: 4 }}>BATTERY</div>
            </div>
          </div>
          {/* Progress bar at bottom */}
          <div style={{ position: 'absolute', left: 22, right: 22, bottom: 14 }}>
            <TripProgressBar progress={progress} stops={STOPS_SAMPLE} compact/>
            <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 4, fontSize: 8.5, color: T.textMuted, letterSpacing: 0.6, fontWeight: 500, textTransform: 'uppercase' }}>
              <span>Home</span><span>Pescadero</span>
            </div>
          </div>
        </div>
      )}
      {expanded && expandedStyle === 'uber' && (
        <div style={{ position: 'absolute', inset: 0, padding: '36px 18px 14px' }}>
          {/* Status header */}
          <div style={{ position: 'absolute', top: 11, left: 22, right: 22, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
              <span style={{ width: 7, height: 7, borderRadius: 4, background: T.gold, boxShadow: `0 0 6px ${T.gold}` }}/>
              <span style={{ fontFamily: T.font, fontSize: 12, fontWeight: 600, color: T.text, letterSpacing: -0.1 }}>{vehicle}</span>
            </div>
            <span style={{ fontFamily: T.font, fontSize: 9.5, color: T.driving, fontWeight: 600, letterSpacing: 0.7 }}>EN ROUTE</span>
          </div>
          {/* Map + primary metric */}
          <div style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
            <div style={{ width: 60, height: 60, borderRadius: 14, overflow: 'hidden', position: 'relative', background: '#0a0a0a', flexShrink: 0 }}>
              <MapBackground width={60} height={60} seed={42}/>
              <svg width="60" height="60" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
                <RouteLine path={route} progress={progress} width={10} glow={false}/>
                <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={22}/>
              </svg>
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
                <span style={{ fontFamily: T.fontNum, fontSize: 28, fontWeight: 300, color: T.gold, lineHeight: 1, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.9 }}>{eta}</span>
                <span style={{ fontSize: 12, color: T.gold, opacity: 0.7 }}>min to Pescadero</span>
              </div>
              <div style={{ marginTop: 6, display: 'flex', gap: 14, fontFamily: T.fontNum, fontSize: 11, color: T.textSec, fontVariantNumeric: 'tabular-nums' }}>
                <span><span style={{ color: T.text, fontWeight: 500 }}>{speed}</span> mph</span>
                <span><span style={{ color: T.text, fontWeight: 500 }}>{Math.round(battery)}</span>%</span>
                <span style={{ color: T.textMuted }}>{Math.round(progress * 100)}% complete</span>
              </div>
            </div>
          </div>
        </div>
      )}
      {expanded && expandedStyle === 'detailed' && (
        <div style={{ position: 'absolute', inset: 0, padding: '40px 20px 16px', display: 'flex', flexDirection: 'column', gap: 12 }}>
          {/* Top row: vehicle + status */}
          <div style={{ position: 'absolute', top: 9, left: 20, right: 20, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ width: 8, height: 8, borderRadius: 4, background: T.gold, boxShadow: `0 0 6px ${T.gold}` }}/>
              <span style={{ fontFamily: T.font, fontSize: 12, fontWeight: 600, color: T.text }}>{vehicle}</span>
            </div>
            <span style={{ fontFamily: T.font, fontSize: 10, color: T.driving, fontWeight: 500, letterSpacing: 0.5 }}>{status === 'driving' ? 'EN ROUTE' : 'PARKED'}</span>
          </div>
          {/* Body: mini map + stats */}
          <div style={{ display: 'flex', gap: 12, flex: 1 }}>
            <div style={{ width: 100, height: 76, borderRadius: 10, overflow: 'hidden', position: 'relative', background: '#0a0a0a' }}>
              <MapBackground width={100} height={76} seed={42}/>
              <svg width="100" height="76" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
                <RouteLine path={route} progress={progress} width={8} glow={false}/>
                <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={16}/>
              </svg>
            </div>
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'space-between', padding: '2px 0' }}>
              <DIStat label="ETA"    value={eta}              unit="min" gold/>
              <DIStat label="SPEED"  value={speed}            unit="mph"/>
              <DIStat label="BATTERY" value={Math.round(battery)} unit="%"/>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
function DIStat({ label, value, unit, gold }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
      <span style={{ fontFamily: T.font, fontSize: 9, fontWeight: 500, color: T.textMuted, letterSpacing: 1, width: 50 }}>{label}</span>
      <span style={{ fontFamily: T.fontNum, fontSize: 15, fontWeight: 500, color: gold ? T.gold : T.text, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3 }}>{value}</span>
      <span style={{ fontFamily: T.font, fontSize: 10, color: T.textMuted }}>{unit}</span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Status bar — white over dark
// ─────────────────────────────────────────────────────────────
function PhoneStatusBar({ time = '9:41' }) {
  return (
    <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 54, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 32px', paddingTop: 18, zIndex: 45, pointerEvents: 'none', fontFamily: T.font }}>
      <span style={{ fontSize: 16, fontWeight: 600, color: T.text, fontVariantNumeric: 'tabular-nums' }}>{time}</span>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <svg width="18" height="11" viewBox="0 0 18 11" fill={T.text}><rect x="0" y="7" width="3" height="4" rx="0.7"/><rect x="4.5" y="5" width="3" height="6" rx="0.7"/><rect x="9" y="2.5" width="3" height="8.5" rx="0.7"/><rect x="13.5" y="0" width="3" height="11" rx="0.7"/></svg>
        <svg width="16" height="11" viewBox="0 0 17 12"><path d="M8.5 3.2C10.8 3.2 12.9 4.1 14.4 5.6L15.5 4.5C13.7 2.7 11.2 1.5 8.5 1.5C5.8 1.5 3.3 2.7 1.5 4.5L2.6 5.6C4.1 4.1 6.2 3.2 8.5 3.2Z" fill={T.text}/><path d="M8.5 6.8C9.9 6.8 11.1 7.3 12 8.2L13.1 7.1C11.8 5.9 10.2 5.1 8.5 5.1C6.8 5.1 5.2 5.9 3.9 7.1L5 8.2C5.9 7.3 7.1 6.8 8.5 6.8Z" fill={T.text}/><circle cx="8.5" cy="10.5" r="1.5" fill={T.text}/></svg>
        <svg width="26" height="12" viewBox="0 0 27 13"><rect x="0.5" y="0.5" width="23" height="12" rx="3.5" stroke={T.text} strokeOpacity="0.45" fill="none"/><rect x="2" y="2" width="20" height="9" rx="2" fill={T.text}/><path d="M25 4.5V8.5C25.8 8.2 26.5 7.2 26.5 6.5C26.5 5.8 25.8 4.8 25 4.5Z" fill={T.text} fillOpacity="0.5"/></svg>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// iPhone 17 Pro frame
// ─────────────────────────────────────────────────────────────
function Phone17Pro({ children, di, diState = 'minimal', onDIClick }) {
  const W = 402, H = 874;
  return (
    <div style={{
      width: W + 24, height: H + 24, borderRadius: 60,
      padding: 12, boxSizing: 'border-box',
      background: 'linear-gradient(155deg, #2a2a2c 0%, #16161a 45%, #28282c 100%)',
      position: 'relative', flexShrink: 0,
      boxShadow: '0 40px 100px rgba(0,0,0,0.6), 0 0 0 1.5px rgba(255,255,255,0.06), inset 0 0 0 2px rgba(0,0,0,0.8)',
    }}>
      {/* Side buttons */}
      <div style={{ position: 'absolute', left: -2, top: 110, width: 4, height: 32, background: '#0d0d0e', borderRadius: 2 }}/>
      <div style={{ position: 'absolute', left: -2, top: 170, width: 4, height: 56, background: '#0d0d0e', borderRadius: 2 }}/>
      <div style={{ position: 'absolute', left: -2, top: 240, width: 4, height: 56, background: '#0d0d0e', borderRadius: 2 }}/>
      <div style={{ position: 'absolute', right: -2, top: 180, width: 4, height: 96, background: '#0d0d0e', borderRadius: 2 }}/>
      {/* Screen */}
      <div id="mrt-screen" style={{
        width: W, height: H, borderRadius: 50,
        background: '#000', position: 'relative', overflow: 'hidden',
      }}>
        {children}
        <PhoneStatusBar/>
        {di || <DynamicIsland state={diState} {...(typeof onDIClick === 'function' ? { onLongPress: onDIClick } : {})}/>}
        {/* Home indicator — always on top */}
        <div style={{ position: 'absolute', bottom: 8, left: 0, right: 0, display: 'flex', justifyContent: 'center', zIndex: 100, pointerEvents: 'none' }}>
          <div style={{ width: 139, height: 5, borderRadius: 99, background: 'rgba(255,255,255,0.55)' }}/>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { DynamicIsland, Phone17Pro, PhoneStatusBar });
