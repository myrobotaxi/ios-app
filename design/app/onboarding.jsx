// MyRoboTaxi — onboarding: Add Your Tesla (owner pairing) + Enter Invite Code (rider).
// Visual language follows the Sign In / Empty screens: matte near-black with a
// soft gold wash from the top, the brand mark, and gold-on-dark accents.
// The Tesla auth screens are an ORIGINAL, plausible third-party OAuth mock —
// not a reproduction of Tesla's actual login UI.

const { useState: oS, useEffect: oE, useRef: oR } = React;

// Brand gold wash shared by every onboarding surface.
function GoldWash() {
  return <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: 360,
    background: `radial-gradient(140% 100% at 50% -20%, ${T.goldGlow3} 0%, rgba(0,0,0,0) 65%)`, pointerEvents: 'none' }}/>;
}

// Small ghost "Skip / Cancel" affordance, top-right.
function TopAction({ label, onClick }) {
  return (
    <button onClick={onClick} style={{
      position: 'absolute', top: 82, right: 20, zIndex: 30,
      background: 'transparent', border: 'none', cursor: 'pointer',
      fontFamily: T.font, fontSize: 15, fontWeight: 500, color: T.textSec, padding: 6 }}>
      {label}
    </button>);
}

// ─────────────────────────────────────────────────────────────
// Pairing stepper — Sign in · Access · Key · Paired
// ─────────────────────────────────────────────────────────────
function PairStepper({ step }) {
  const steps = ['Sign in', 'Linked', 'Virtual key', 'Paired'];
  return (
    <div style={{ position: 'absolute', top: 124, left: 28, right: 28, zIndex: 25, display: 'flex', alignItems: 'flex-start' }}>
      {steps.map((label, i) => {
        const done = i < step, active = i === step;
        const c = done || active ? T.goldDeep : 'rgba(255,255,255,0.18)';
        return (
          <React.Fragment key={i}>
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, width: 46, flexShrink: 0 }}>
              <div style={{ width: 26, height: 26, borderRadius: 13, flexShrink: 0,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                background: done ? T.goldDeep : active ? 'rgba(140,110,42,0.18)' : 'rgba(255,255,255,0.05)',
                border: `1.5px solid ${c}`,
                boxShadow: active ? `0 0 0 4px rgba(140,110,42,0.12)` : 'none',
                transition: 'all .3s ease' }}>
                {done
                  ? <SFIcon name="checkmark" size={14} color="#1c1505" weight={2.4}/>
                  : <span style={{ fontFamily: T.fontNum, fontSize: 12, fontWeight: 600, color: active ? T.goldDeepSoft : T.textMuted }}>{i + 1}</span>}
              </div>
              <div style={{ fontSize: 9.5, fontWeight: 600, letterSpacing: 0.2, textAlign: 'center', lineHeight: 1.15,
                color: done || active ? T.goldDeepSoft : T.textMuted }}>{label}</div>
            </div>
            {i < steps.length - 1 &&
              <div style={{ flex: 1, height: 1.5, borderRadius: 1, marginTop: 12.5,
                background: i < step ? T.goldDeep : 'rgba(255,255,255,0.12)', transition: 'background .3s ease' }}/>}
          </React.Fragment>);
      })}
    </div>);
}

// ─────────────────────────────────────────────────────────────
// In-app browser (Safari-View-Controller style) — hosts the Tesla OAuth.
// Slides up over the app, then auto-dismisses the instant access is granted.
// ─────────────────────────────────────────────────────────────
function InAppBrowser({ open, onGranted, onCancel, scopesGranted }) {
  const [view, setView] = oS('auth'); // auth → consent → connecting
  const [pw, setPw] = oS('');

  oE(() => { if (open) { setView('auth'); setPw(''); } }, [open]);

  // After consent, show a brief "connecting" beat, then hand back to the app.
  oE(() => {
    if (view !== 'connecting') return;
    const t = setTimeout(() => onGranted(), 1150);
    return () => clearTimeout(t);
  }, [view]);

  const SCOPES = [
    { icon: 'car.fill',      title: 'Vehicle information', sub: 'Model, battery, status' },
    { icon: 'location.fill', title: 'Location',            sub: 'Live position while shared' },
    { icon: 'lock.fill',     title: 'Commands',            sub: 'Lock, climate, media' },
    { icon: 'bolt.fill',     title: 'Charging',            sub: 'Start, stop, monitor' },
  ];

  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 300, pointerEvents: open ? 'auto' : 'none' }}>
      {/* dim behind */}
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.55)',
        opacity: open ? 1 : 0, transition: 'opacity .35s ease' }}/>
      {/* browser sheet */}
      <div style={{ position: 'absolute', top: 20, left: 0, right: 0, bottom: 0,
        background: '#F2F2F4', borderTopLeftRadius: 40, borderTopRightRadius: 40, overflow: 'hidden',
        transform: open ? 'translateY(0)' : 'translateY(100%)',
        transition: 'transform .42s cubic-bezier(0.32,0.72,0,1)',
        boxShadow: '0 -30px 80px rgba(0,0,0,0.6)', display: 'flex', flexDirection: 'column' }}>
        {/* faux Safari chrome */}
        <div style={{ paddingTop: 14, paddingBottom: 12, paddingLeft: 18, paddingRight: 18, background: '#E8E8EC',
          borderBottom: '0.5px solid rgba(0,0,0,0.12)', display: 'flex', alignItems: 'center', gap: 12 }}>
          <button onClick={onCancel} style={{ background: 'none', border: 'none', cursor: 'pointer',
            fontFamily: T.font, fontSize: 15, fontWeight: 400, color: '#0A84FF', padding: 0 }}>Cancel</button>
          <div style={{ flex: 1, height: 34, borderRadius: 10, background: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6, color: '#1c1c1e' }}>
            <svg width="11" height="13" viewBox="0 0 11 13" fill="none"><rect x="1" y="5.6" width="9" height="6.4" rx="1.6" fill="#3a3a3c"/><path d="M3 5.6V4a2.5 2.5 0 0 1 5 0v1.6" stroke="#3a3a3c" strokeWidth="1.3" fill="none"/></svg>
            <span style={{ fontFamily: T.font, fontSize: 13.5, fontWeight: 400, letterSpacing: -0.1 }}>auth.tesla.com</span>
          </div>
          <div style={{ width: 18, height: 18, borderRadius: 9, border: '1.6px solid #8e8e93', borderTopColor: 'transparent',
            animation: 'mrtBrowserSpin 0.9s linear infinite', opacity: view === 'connecting' ? 1 : 0, transition: 'opacity .2s' }}/>
        </div>

        {/* page body */}
        <div style={{ flex: 1, overflowY: 'auto', position: 'relative' }}>
          {/* AUTH */}
          <div style={{ padding: '40px 30px 30px', opacity: view === 'auth' ? 1 : 0,
            transform: view === 'auth' ? 'none' : 'translateX(-16px)', pointerEvents: view === 'auth' ? 'auto' : 'none',
            transition: 'opacity .3s, transform .3s', position: view === 'auth' ? 'relative' : 'absolute', inset: 0 }}>
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', marginBottom: 34 }}>
              <div style={{ width: 46, height: 46, borderRadius: 12, background: '#E82127',
                display: 'flex', alignItems: 'center', justifyContent: 'center', marginBottom: 16,
                boxShadow: '0 6px 18px rgba(232,33,39,0.32)' }}>
                <span style={{ fontFamily: T.font, fontSize: 26, fontWeight: 700, color: '#fff', lineHeight: 1 }}>T</span>
              </div>
              <div style={{ fontFamily: T.font, fontSize: 19, fontWeight: 600, color: '#1c1c1e', letterSpacing: -0.3 }}>Sign in to Tesla</div>
              <div style={{ fontFamily: T.font, fontSize: 13.5, color: '#6b6b70', marginTop: 5 }}>to continue to MyRoboTaxi</div>
            </div>
            <label style={{ fontFamily: T.font, fontSize: 12, fontWeight: 600, color: '#6b6b70', display: 'block', marginBottom: 7 }}>Email</label>
            <div style={{ height: 48, borderRadius: 12, background: '#fff', border: '0.5px solid rgba(0,0,0,0.14)',
              display: 'flex', alignItems: 'center', padding: '0 14px', marginBottom: 16,
              fontFamily: T.font, fontSize: 15, color: '#1c1c1e' }}>owner@icloud.com</div>
            <label style={{ fontFamily: T.font, fontSize: 12, fontWeight: 600, color: '#6b6b70', display: 'block', marginBottom: 7 }}>Password</label>
            <input type="password" value={pw} onChange={(e) => setPw(e.target.value)} placeholder="••••••••"
              style={{ width: '100%', height: 48, borderRadius: 12, background: '#fff', border: '0.5px solid rgba(0,0,0,0.14)',
                padding: '0 14px', marginBottom: 24, fontFamily: T.font, fontSize: 15, color: '#1c1c1e', outline: 'none', boxSizing: 'border-box' }}/>
            <button onClick={() => setView('consent')} style={{ width: '100%', height: 50, borderRadius: 12, border: 'none', cursor: 'pointer',
              background: '#E82127', color: '#fff', fontFamily: T.font, fontSize: 16, fontWeight: 600,
              boxShadow: '0 6px 18px rgba(232,33,39,0.3)' }}>Sign In</button>
            <div style={{ textAlign: 'center', marginTop: 18, fontFamily: T.font, fontSize: 13, color: '#0A84FF', fontWeight: 500 }}>Forgot password?</div>
          </div>

          {/* CONSENT */}
          {view !== 'auth' &&
          <div style={{ padding: '34px 26px 30px', opacity: view === 'consent' ? 1 : 0.4, transition: 'opacity .3s' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 11, marginBottom: 8, justifyContent: 'center' }}>
              <div style={{ width: 38, height: 38, borderRadius: 10, background: '#E82127', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <span style={{ fontFamily: T.font, fontSize: 21, fontWeight: 700, color: '#fff', lineHeight: 1 }}>T</span>
              </div>
              <svg width="22" height="10" viewBox="0 0 22 10"><path d="M0 5h18M14 1l5 4-5 4" stroke="#b0b0b5" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round"/></svg>
              <div style={{ transform: 'scale(1.0)' }}><HexLogo size={38}/></div>
            </div>
            <div style={{ fontFamily: T.font, fontSize: 19, fontWeight: 600, color: '#1c1c1e', textAlign: 'center', letterSpacing: -0.3, marginTop: 14, padding: '0 10px' }}>
              MyRoboTaxi wants access to your Tesla
            </div>
            <div style={{ fontFamily: T.font, fontSize: 13, color: '#6b6b70', textAlign: 'center', marginTop: 6, marginBottom: 22 }}>
              Review what you're sharing
            </div>
            <div style={{ background: '#fff', borderRadius: 16, border: '0.5px solid rgba(0,0,0,0.10)', overflow: 'hidden', marginBottom: 22 }}>
              {SCOPES.map((s, i) =>
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '13px 16px',
                  borderTop: i ? '0.5px solid rgba(0,0,0,0.07)' : 'none' }}>
                  <div style={{ width: 34, height: 34, borderRadius: 9, background: 'rgba(232,33,39,0.08)', flexShrink: 0,
                    display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                    <SFIcon name={s.icon} size={18} color="#E82127"/>
                  </div>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontFamily: T.font, fontSize: 14.5, fontWeight: 600, color: '#1c1c1e' }}>{s.title}</div>
                    <div style={{ fontFamily: T.font, fontSize: 12, color: '#8a8a8f', marginTop: 1 }}>{s.sub}</div>
                  </div>
                  <SFIcon name="checkmark" size={15} color="#34A853" weight={2.2}/>
                </div>)}
            </div>
            <button onClick={() => setView('connecting')} style={{ width: '100%', height: 50, borderRadius: 12, border: 'none', cursor: 'pointer',
              background: '#1c1c1e', color: '#fff', fontFamily: T.font, fontSize: 16, fontWeight: 600 }}>Allow access</button>
            <button onClick={onCancel} style={{ width: '100%', height: 46, marginTop: 8, borderRadius: 12, border: 'none', cursor: 'pointer',
              background: 'transparent', color: '#6b6b70', fontFamily: T.font, fontSize: 15, fontWeight: 500 }}>Cancel</button>
            <div style={{ fontFamily: T.font, fontSize: 11, color: '#a0a0a5', textAlign: 'center', marginTop: 14, lineHeight: 1.5 }}>
              You can revoke access anytime in your Tesla account.
            </div>
          </div>}

          {/* CONNECTING overlay */}
          {view === 'connecting' &&
          <div style={{ position: 'absolute', inset: 0, background: 'rgba(242,242,244,0.92)', backdropFilter: 'blur(2px)',
            display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 18 }}>
            <div style={{ width: 38, height: 38, borderRadius: 19, border: '3px solid rgba(0,0,0,0.12)', borderTopColor: '#E82127',
              animation: 'mrtBrowserSpin 0.8s linear infinite' }}/>
            <div style={{ fontFamily: T.font, fontSize: 15, fontWeight: 600, color: '#1c1c1e' }}>Connecting to MyRoboTaxi…</div>
          </div>}
        </div>
      </div>
    </div>);
}

// ─────────────────────────────────────────────────────────────
// Add Your Tesla — full pairing flow.
// intro → (in-app browser auth+consent) → key → authorizing → paired
// ─────────────────────────────────────────────────────────────
function AddTeslaFlow({ onComplete, onCancel }) {
  const [phase, setPhase] = oS('intro'); // intro | linked | key | waiting | paired
  const [browser, setBrowser] = oS(false);
  const vehicle = (window.VEHICLES && window.VEHICLES[0]) || { name: 'Cybercab', model: '2026 Tesla Cybercab', color: 'Mercury Silver', plate: 'RBO-2046' };

  const stepFor = { intro: 0, linked: 2, key: 2, waiting: 2, paired: 3 }[phase];
  const browserStep = browser ? 1 : stepFor;

  const openBrowser = () => setBrowser(true);
  const onGranted = () => { setBrowser(false); setPhase('linked'); };

  const openTeslaApp = () => {
    setPhase('waiting');
    setTimeout(() => setPhase('paired'), 2400);
  };

  return (
    <div style={{ height: '100%', background: T.bg, position: 'relative', overflow: 'hidden' }}>
      <style>{`
        @keyframes mrtBrowserSpin { to { transform: rotate(360deg); } }
        @keyframes mrtKeyFloat { 0%,100% { transform: translateY(0); } 50% { transform: translateY(-7px); } }
        @keyframes mrtRingPulse { 0% { transform: translate(-50%,-50%) scale(0.4); opacity: 0.7; } 100% { transform: translate(-50%,-50%) scale(2.6); opacity: 0; } }
        @keyframes mrtPairBloom { 0% { opacity: 0; transform: translate(-50%,-50%) scale(0.2); } 30% { opacity: 0.9; } 100% { opacity: 0; transform: translate(-50%,-50%) scale(3.4); } }
        @keyframes mrtCardRise { from { opacity: 0; transform: translateY(22px) scale(0.96); } to { opacity: 1; transform: none; } }
        @keyframes mrtCheckPop { 0% { transform: scale(0); } 60% { transform: scale(1.18); } 100% { transform: scale(1); } }
        @keyframes mrtFadeUp { from { opacity: 0; transform: translateY(12px); } to { opacity: 1; transform: none; } }
        @keyframes mrtWaitDot { 0%,80%,100% { opacity: 0.25; } 40% { opacity: 1; } }
        @keyframes mrtShimmer { 0% { transform: translateX(-160%) skewX(-12deg); } 55%,100% { transform: translateX(280%) skewX(-12deg); } }
        @keyframes mrtCardPulse { 0% { transform: translate(-50%,-50%) scale(0.92); opacity: 0.55; } 100% { transform: translate(-50%,-50%) scale(1.5); opacity: 0; } }
        @keyframes mrtBadgePop { 0% { transform: scale(0); opacity: 0; } 60% { transform: scale(1.15); } 100% { transform: scale(1); opacity: 1; } }
        @keyframes mrtCheckDraw { to { stroke-dashoffset: 0; } }
        @keyframes mrtBadgeRing { 0% { transform: scale(0.6); opacity: 0.7; } 100% { transform: scale(2.1); opacity: 0; } }
        @keyframes mrtTextWord { from { opacity: 0; transform: translateX(-6px); filter: blur(3px); } to { opacity: 1; transform: none; filter: blur(0); } }
      `}</style>
      <GoldWash/>
      <PairStepper step={browserStep}/>
      {phase === 'intro' && <TopAction label="Cancel" onClick={onCancel}/>}

      {/* INTRO */}
      {phase === 'intro' &&
      <div style={{ position: 'absolute', inset: 0, paddingTop: 196, paddingBottom: 38, paddingLeft: 30, paddingRight: 30,
        display: 'flex', flexDirection: 'column', animation: 'mrtFadeUp .4s ease both' }}>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ position: 'relative', marginBottom: 34 }}>
            <div style={{ position: 'absolute', top: '50%', left: '50%', width: 130, height: 130, borderRadius: '50%',
              border: `1px solid ${T.gold}44`, animation: 'mrtRingPulse 2.6s ease-out infinite' }}/>
            <div style={{ position: 'absolute', top: '50%', left: '50%', width: 130, height: 130, borderRadius: '50%',
              border: `1px solid ${T.gold}44`, animation: 'mrtRingPulse 2.6s ease-out 1.3s infinite' }}/>
            <HexLogo size={76} glow/>
          </div>
          <div style={{ fontSize: 25, fontWeight: 600, color: T.text, letterSpacing: -0.5, textAlign: 'center', marginBottom: 12 }}>Connect your Tesla</div>
          <div style={{ fontSize: 14.5, color: T.textSec, textAlign: 'center', maxWidth: 290, lineHeight: 1.55 }}>
            Sign in with your Tesla account to securely link your vehicle. You'll grant access, then approve a virtual key — it only takes a minute.
          </div>
        </div>
        <Button variant="outline-static" onClick={openBrowser}>Sign in with Tesla</Button>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, marginTop: 16 }}>
          <SFIcon name="lock.fill" size={12} color={T.textMuted}/>
          <span style={{ fontSize: 11.5, color: T.textMuted }}>Secured by Tesla — we never see your password.</span>
        </div>
      </div>}

      {/* LINKED — green-check beat after returning from the in-app browser */}
      {phase === 'linked' && <LinkedTransition onDone={() => setPhase('key')} />}

      {/* VIRTUAL KEY */}
      {(phase === 'key' || phase === 'waiting') &&
      <div style={{ position: 'absolute', inset: 0, paddingTop: 196, paddingBottom: 38, paddingLeft: 30, paddingRight: 30,
        display: 'flex', flexDirection: 'column', animation: 'mrtFadeUp .4s ease both' }}>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>
          {/* Virtual key card — matte black, centered etched wordmark (à la a real key card) */}
          <div style={{ position: 'relative', width: 176, height: 112, marginBottom: 30 }}>
            {phase === 'waiting' && <>
              <div style={{ position: 'absolute', top: '50%', left: '50%', width: 176, height: 112, borderRadius: 14,
                border: `1.5px solid ${T.gold}55`, animation: 'mrtCardPulse 1.8s ease-out infinite' }}/>
              <div style={{ position: 'absolute', top: '50%', left: '50%', width: 176, height: 112, borderRadius: 14,
                border: `1.5px solid ${T.gold}55`, animation: 'mrtCardPulse 1.8s ease-out 0.9s infinite' }}/>
            </>}
            <div style={{ position: 'relative', width: 176, height: 112, borderRadius: 14, overflow: 'hidden',
              background: 'linear-gradient(155deg, #1a1a1a 0%, #0d0d0d 52%, #050505 100%)',
              border: '0.5px solid rgba(255,255,255,0.10)',
              boxShadow: `0 16px 36px rgba(0,0,0,0.6), 0 0 26px ${T.goldGlow3}, inset 0 1px 0 rgba(255,255,255,0.07)`,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              animation: phase === 'waiting' ? 'mrtKeyFloat 1.8s ease-in-out infinite' : 'none' }}>
              {/* shimmer sweep — reads as the etched-metal catching light */}
              <div style={{ position: 'absolute', top: 0, bottom: 0, left: 0, width: '46%',
                background: 'linear-gradient(100deg, rgba(255,255,255,0) 0%, rgba(255,255,255,0.16) 50%, rgba(255,255,255,0) 100%)',
                animation: 'mrtShimmer 2.8s ease-in-out infinite', pointerEvents: 'none' }}/>
              {/* centered metallic-etched wordmark */}
              <div style={{ position: 'relative', fontFamily: '"Roboto", ' + T.font, fontSize: 17, fontWeight: 500,
                letterSpacing: 2.4, textTransform: 'uppercase', lineHeight: 1,
                backgroundImage: 'linear-gradient(180deg, #f5ecc8 0%, #c9a84c 48%, #8a6e23 100%)',
                WebkitBackgroundClip: 'text', backgroundClip: 'text', WebkitTextFillColor: 'transparent',
                filter: 'drop-shadow(0 0.5px 0 rgba(0,0,0,0.6))' }}>myrobotaxi</div>
            </div>
          </div>

          {phase === 'key' ? <>
            <div style={{ fontSize: 23, fontWeight: 600, color: T.text, letterSpacing: -0.4, textAlign: 'center', marginBottom: 12 }}>Authorize a virtual key</div>
            <div style={{ fontSize: 14, color: T.textSec, textAlign: 'center', maxWidth: 296, lineHeight: 1.55 }}>
              Open the Tesla app and approve the key request. This lets MyRoboTaxi unlock, command, and dispatch your <b style={{ color: T.text, fontWeight: 600 }}>{vehicle.name}</b>.
            </div>
          </> : <>
            <div style={{ fontSize: 21, fontWeight: 600, color: T.text, letterSpacing: -0.4, textAlign: 'center', marginBottom: 10 }}>Waiting for approval…</div>
            <div style={{ fontSize: 13.5, color: T.textSec, textAlign: 'center', maxWidth: 280, lineHeight: 1.5 }}>
              Approve the virtual key request in the Tesla app to finish pairing.
            </div>
            <div style={{ display: 'flex', gap: 6, marginTop: 18 }}>
              {[0,1,2].map(i => <span key={i} style={{ width: 7, height: 7, borderRadius: 4, background: T.gold, animation: `mrtWaitDot 1.4s ease-in-out ${i*0.18}s infinite` }}/>)}
            </div>
            <div style={{ fontSize: 10.5, color: T.textMuted, marginTop: 20, fontStyle: 'italic' }}>Simulating Tesla-app handoff…</div>
          </>}
        </div>
        {phase === 'key' &&
        <Button variant="outline-static" onClick={openTeslaApp} icon={<SFIcon name="arrow.up.right" size={16} color={T.gold}/>}>Open Tesla app</Button>}
      </div>}

      {/* PAIRED — celebratory */}
      {phase === 'paired' &&
      <PairedSuccess vehicle={vehicle} onContinue={onComplete}/>}

      {/* In-app browser */}
      <InAppBrowser open={browser} onGranted={onGranted} onCancel={() => setBrowser(false)}/>
    </div>);
}

// Green-check success beat shown when the user returns from the in-app browser,
// before the virtual-key screen.
function LinkedTransition({ onDone }) {
  oE(() => { const t = setTimeout(onDone, 1750); return () => clearTimeout(t); }, []);
  return (
    <div style={{ position: 'absolute', inset: 0, paddingTop: 196, paddingBottom: 38, paddingLeft: 30, paddingRight: 30,
      display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', animation: 'mrtFadeUp .4s ease both' }}>
      <div style={{ position: 'relative', width: 86, height: 86, marginBottom: 30 }}>
        {[0, 1].map((i) =>
          <span key={i} style={{ position: 'absolute', top: '50%', left: '50%', width: 86, height: 86, borderRadius: 43,
            border: `1.5px solid ${T.driving}`, animation: `mrtBadgeRing 1.5s ease-out ${0.3 + i * 0.45}s both`, pointerEvents: 'none' }}/>)}
        <div style={{ width: 86, height: 86, borderRadius: 43,
          background: `linear-gradient(160deg, #3ee06a, ${T.driving})`,
          boxShadow: `0 14px 36px rgba(48,209,88,0.45), inset 0 1px 0 rgba(255,255,255,0.45)`,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          animation: 'mrtBadgePop 0.6s cubic-bezier(0.34,1.56,0.64,1) both' }}>
          <svg width="46" height="46" viewBox="0 0 24 24" fill="none" stroke="#0a2912" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
            <path d="M5 12.5l4.5 4.5L19 6.5" style={{ strokeDasharray: 24, strokeDashoffset: 24, animation: 'mrtCheckDraw 0.5s ease-out 0.36s forwards' }}/>
          </svg>
        </div>
      </div>
      <div style={{ fontSize: 24, fontWeight: 600, color: T.text, letterSpacing: -0.4, marginBottom: 9, animation: 'mrtTextWord 0.5s ease-out 0.42s both' }}>Tesla account linked</div>
      <div style={{ fontSize: 14, color: T.textSec, animation: 'mrtTextWord 0.5s ease-out 0.52s both' }}>Secure connection established</div>
    </div>);
}

function PairedSuccess({ vehicle, onContinue }) {
  const [showCard, setShowCard] = oS(false);
  oE(() => { const t = setTimeout(() => setShowCard(true), 480); return () => clearTimeout(t); }, []);
  return (
    <div style={{ position: 'absolute', inset: 0, paddingTop: 150, paddingBottom: 38, paddingLeft: 30, paddingRight: 30,
      display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      {/* gold blooms */}
      <div style={{ position: 'absolute', top: '42%', left: '50%', width: 300, height: 300, borderRadius: '50%',
        background: `radial-gradient(circle, ${T.gold} 0%, rgba(201,168,76,0.4) 34%, rgba(201,168,76,0) 68%)`,
        animation: 'mrtPairBloom 0.9s cubic-bezier(0.4,0,0.2,1) forwards', pointerEvents: 'none' }}/>
      {[0,1,2].map(i =>
        <div key={i} style={{ position: 'absolute', top: '42%', left: '50%', width: 160, height: 160, borderRadius: '50%',
          border: `1.5px solid ${T.gold}55`, animation: `mrtRingPulse 2.2s ease-out ${i*0.5}s infinite`, pointerEvents: 'none' }}/>)}

      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', position: 'relative', zIndex: 2 }}>
        {/* check */}
        <div style={{ width: 72, height: 72, borderRadius: 36, background: T.gold, marginBottom: 26,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          boxShadow: `0 10px 34px ${T.goldGlow6}`, animation: 'mrtCheckPop 0.5s cubic-bezier(0.34,1.56,0.64,1) both' }}>
          <SFIcon name="checkmark" size={36} color="#1a1408" weight={2.6}/>
        </div>
        <div style={{ fontSize: 26, fontWeight: 600, color: T.text, letterSpacing: -0.5, marginBottom: 8, animation: 'mrtFadeUp .5s ease .15s both' }}>You're paired</div>
        <div style={{ fontSize: 14, color: T.textSec, marginBottom: 30, animation: 'mrtFadeUp .5s ease .25s both' }}>Your Tesla is ready to go.</div>

        {/* vehicle card reveal (no illustration — the real product card) */}
        <div style={{ width: '100%', borderRadius: 20, padding: 18, position: 'relative', overflow: 'hidden',
          background: 'linear-gradient(160deg, rgba(201,168,76,0.14), rgba(255,255,255,0.03))',
          border: `0.5px solid ${T.gold}3a`, boxShadow: `0 16px 40px rgba(0,0,0,0.45)`,
          opacity: showCard ? 1 : 0, animation: showCard ? 'mrtCardRise 0.55s cubic-bezier(0.22,1,0.36,1) both' : 'none' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <HexLogo size={52} glow/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 19, fontWeight: 600, color: T.text, letterSpacing: -0.3 }}>{vehicle.name}</div>
              <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 2 }}>{vehicle.model}</div>
            </div>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 11px', borderRadius: 14,
              background: 'rgba(48,209,88,0.12)', border: `0.5px solid ${T.driving}44` }}>
              <PulseDot color={T.driving} size={6}/>
              <span style={{ fontSize: 11, fontWeight: 600, color: T.driving }}>Paired</span>
            </div>
          </div>
          <div style={{ display: 'flex', gap: 18, marginTop: 16, paddingTop: 14, borderTop: '0.5px solid rgba(255,255,255,0.08)' }}>
            {[['Color', vehicle.color], ['Plate', vehicle.plate], ['Virtual key', 'Active']].map(([l, v], i) =>
              <div key={i} style={{ flex: 1 }}>
                <div style={{ fontSize: 9.5, color: T.textMuted, letterSpacing: 0.6, textTransform: 'uppercase', fontWeight: 600 }}>{l}</div>
                <div style={{ fontSize: 13, color: i === 2 ? T.gold : T.text, fontWeight: 500, marginTop: 3 }}>{v}</div>
              </div>)}
          </div>
        </div>
      </div>
      <div style={{ animation: 'mrtFadeUp .5s ease .5s both', position: 'relative', zIndex: 2 }}>
        <Button variant="outline-static" onClick={onContinue}>Continue</Button>
      </div>
    </div>);
}

// ─────────────────────────────────────────────────────────────
// Enter Invite Code — rider join flow.
// entry → validating → joined
// ─────────────────────────────────────────────────────────────
function InviteCodeFlow({ onComplete, onCancel, returning }) {
  const LEN = 6;
  const SAMPLE = 'RBO246';
  const [code, setCode] = oS('');
  const [phase, setPhase] = oS('entry'); // entry | validating | joined
  const [shake, setShake] = oS(false);
  const inputRef = oR(null);
  const host = (window.FLEET && window.FLEET[0]) || { owner: 'Alex', rel: 'Roommate', name: 'Model Y', model: '2025 Tesla Model Y', color: 'Quicksilver', plate: 'RBO-2046' };

  oE(() => { if (phase === 'entry') setTimeout(() => inputRef.current && inputRef.current.focus(), 350); }, [phase]);

  const submit = (val) => {
    setPhase('validating');
    setTimeout(() => {
      // forgiving: any 6 chars joins (prototype)
      setPhase('joined');
    }, 1300);
  };

  const onChange = (e) => {
    const v = e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, LEN);
    setCode(v);
    if (v.length === LEN) submit(v);
  };

  return (
    <div style={{ height: '100%', background: T.bg, position: 'relative', overflow: 'hidden' }}>
      <style>{`
        @keyframes mrtShake { 0%,100% { transform: translateX(0); } 20%,60% { transform: translateX(-7px); } 40%,80% { transform: translateX(7px); } }
      `}</style>
      <GoldWash/>
      {phase === 'entry' && <TopAction label="Cancel" onClick={onCancel}/>}

      {phase !== 'joined' &&
      <div style={{ position: 'absolute', inset: 0, paddingTop: 132, paddingBottom: 38, paddingLeft: 30, paddingRight: 30,
        display: 'flex', flexDirection: 'column', animation: 'mrtFadeUp .4s ease both' }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', marginBottom: 40 }}>
          <div style={{ marginBottom: 26 }}><HexLogo size={60} glow/></div>
          <div style={{ fontSize: 25, fontWeight: 600, color: T.text, letterSpacing: -0.5, marginBottom: 12, textAlign: 'center' }}>Enter invite code</div>
          <div style={{ fontSize: 14, color: T.textSec, textAlign: 'center', maxWidth: 280, lineHeight: 1.55 }}>
            Ask the vehicle's owner for their 6-character code to join and request rides.
          </div>
        </div>

        {/* code cells */}
        <div onClick={() => inputRef.current && inputRef.current.focus()}
          style={{ display: 'flex', gap: 9, justifyContent: 'center', cursor: 'text',
            animation: shake ? 'mrtShake 0.4s ease' : 'none' }}>
          {Array.from({ length: LEN }).map((_, i) => {
            const ch = code[i];
            const active = i === code.length && phase === 'entry';
            return (
              <div key={i} style={{ width: 44, height: 56, borderRadius: 13,
                background: ch ? 'rgba(201,168,76,0.10)' : 'rgba(255,255,255,0.04)',
                border: `1px solid ${active ? T.gold : ch ? `${T.gold}66` : 'rgba(255,255,255,0.12)'}`,
                boxShadow: active ? `0 0 0 3px rgba(201,168,76,0.12)` : 'none',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontFamily: T.fontNum, fontSize: 24, fontWeight: 600, color: T.text,
                transition: 'all .18s ease' }}>
                {ch || (active ? <span style={{ width: 2, height: 26, background: T.gold, borderRadius: 1, animation: 'mrtCaretBlink 1s steps(1) infinite' }}/> : '')}
              </div>);
          })}
        </div>
        <input ref={inputRef} value={code} onChange={onChange} maxLength={LEN}
          autoCapitalize="characters" autoCorrect="off" spellCheck={false}
          disabled={phase !== 'entry'}
          style={{ position: 'absolute', opacity: 0, pointerEvents: 'none', width: 1, height: 1 }}/>
        <style>{`@keyframes mrtCaretBlink { 50% { opacity: 0; } }`}</style>

        {phase === 'validating' &&
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10, marginTop: 26 }}>
          <div style={{ width: 18, height: 18, borderRadius: 9, border: `2px solid ${T.gold}44`, borderTopColor: T.gold, animation: 'mrtBrowserSpin 0.8s linear infinite' }}/>
          <span style={{ fontSize: 13.5, color: T.textSec, fontWeight: 500 }}>Verifying code…</span>
        </div>}

        <div style={{ flex: 1 }}/>
        <button onClick={() => { setCode(SAMPLE); setTimeout(() => submit(SAMPLE), 200); }}
          disabled={phase !== 'entry'}
          style={{ background: 'transparent', border: 'none', cursor: 'pointer', padding: 10,
            fontFamily: T.font, fontSize: 13, fontWeight: 500, color: T.gold, opacity: phase === 'entry' ? 1 : 0.4 }}>
          Use sample code →
        </button>
      </div>}

      {/* JOINED */}
      {phase === 'joined' &&
      <JoinedSuccess host={host} onContinue={onComplete} cta={returning ? 'Done' : 'Continue'}/>}
    </div>);
}

function JoinedSuccess({ host, onContinue, cta = 'Continue' }) {
  const [showCard, setShowCard] = oS(false);
  oE(() => { const t = setTimeout(() => setShowCard(true), 420); return () => clearTimeout(t); }, []);
  return (
    <div style={{ position: 'absolute', inset: 0, paddingTop: 150, paddingBottom: 38, paddingLeft: 30, paddingRight: 30,
      display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      <div style={{ position: 'absolute', top: '42%', left: '50%', width: 280, height: 280, borderRadius: '50%',
        background: `radial-gradient(circle, ${T.gold} 0%, rgba(201,168,76,0.35) 34%, rgba(201,168,76,0) 68%)`,
        animation: 'mrtPairBloom 0.9s cubic-bezier(0.4,0,0.2,1) forwards', pointerEvents: 'none' }}/>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', position: 'relative', zIndex: 2 }}>
        <div style={{ width: 72, height: 72, borderRadius: 36, background: T.gold, marginBottom: 26,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          boxShadow: `0 10px 34px ${T.goldGlow6}`, animation: 'mrtCheckPop 0.5s cubic-bezier(0.34,1.56,0.64,1) both' }}>
          <SFIcon name="checkmark" size={36} color="#1a1408" weight={2.6}/>
        </div>
        <div style={{ fontSize: 26, fontWeight: 600, color: T.text, letterSpacing: -0.5, marginBottom: 8, animation: 'mrtFadeUp .5s ease .15s both' }}>You're in</div>
        <div style={{ fontSize: 14, color: T.textSec, marginBottom: 30, textAlign: 'center', animation: 'mrtFadeUp .5s ease .25s both' }}>
          You can now ride in {host.owner}'s Tesla.
        </div>
        <div style={{ width: '100%', borderRadius: 20, padding: 18,
          background: 'linear-gradient(160deg, rgba(201,168,76,0.14), rgba(255,255,255,0.03))',
          border: `0.5px solid ${T.gold}3a`, boxShadow: `0 16px 40px rgba(0,0,0,0.45)`,
          opacity: showCard ? 1 : 0, animation: showCard ? 'mrtCardRise 0.55s cubic-bezier(0.22,1,0.36,1) both' : 'none' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 13 }}>
            <Avatar name={host.owner} size={48}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>{host.owner}'s {host.name}</div>
              <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 2 }}>{host.rel} · {host.model}</div>
            </div>
            <SFIcon name="car.fill" size={22} color={T.gold}/>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 14, paddingTop: 13, borderTop: '0.5px solid rgba(255,255,255,0.08)' }}>
            <SFIcon name="checkmark" size={13} color={T.driving} weight={2.4}/>
            <span style={{ fontSize: 12.5, color: T.textSec }}>You can request rides and watch the live map.</span>
          </div>
        </div>
      </div>
      <div style={{ animation: 'mrtFadeUp .5s ease .5s both', position: 'relative', zIndex: 2 }}>
        <Button variant="outline-static" onClick={onContinue}>{cta}</Button>
      </div>
    </div>);
}

Object.assign(window, { AddTeslaFlow, InviteCodeFlow });
