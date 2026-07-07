// MyRoboTaxi · iOS Design System — Component gallery.
// Live components + per-component specs (pt · token · interaction · a11y).

const { useState: cgS } = React;

// One documented component: live preview + spec sidebar.
function ComponentDoc({ name, tag, blurb, preview, previewBg = 'panel', previewH = 150, specs = [], interaction, a11y, wide }) {
  return (
    <Card pad={0} style={{ overflow: 'hidden' }}>
      <div style={{ display: 'flex', flexWrap: 'wrap' }}>
        {/* Preview */}
        <div style={{ flex: wide ? '1 1 100%' : '1 1 300px', minWidth: 0, position: 'relative', borderRight: wide ? 'none' : `0.5px solid ${T.border}`, borderBottom: wide ? `0.5px solid ${T.border}` : 'none' }}>
          <Bay h={previewH} bg={previewBg} pad={24} style={{ gap: 0 }}>{preview}</Bay>
        </div>
        {/* Specs */}
        <div style={{ flex: '1 1 280px', minWidth: 0, padding: '20px 22px' }}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 6 }}>
            <h4 style={{ fontSize: 16, fontWeight: 600, color: T.text, margin: 0, letterSpacing: -0.2 }}>{name}</h4>
            {tag && <span style={{ fontFamily: DS_MONO, fontSize: 11, color: T.gold }}>{tag}</span>}
          </div>
          {blurb && <p style={{ fontSize: 12.5, color: T.textSec, lineHeight: 1.5, margin: '0 0 12px' }}>{blurb}</p>}
          <div style={{ borderTop: `0.5px solid ${T.border}`, paddingTop: 6 }}>
            {specs.map((s, i) => <Spec key={i} k={s[0]} v={s[1]} gold={s[2]} />)}
          </div>
          {interaction && (
            <div style={{ marginTop: 12, paddingTop: 12, borderTop: `0.5px solid ${T.border}`, display: 'flex', gap: 8 }}>
              <span style={{ flexShrink: 0, marginTop: 1 }}><SFIcon name="figure.wave" size={13} color={T.gold} /></span>
              <span style={{ fontSize: 12, color: T.textSec, lineHeight: 1.5 }}><b style={{ color: T.text, fontWeight: 600 }}>Interaction.</b> {interaction}</span>
            </div>
          )}
          {a11y && (
            <div style={{ marginTop: 10, display: 'flex', gap: 8 }}>
              <span style={{ flexShrink: 0, marginTop: 1 }}><SFIcon name="person.fill" size={12} color={T.driving} /></span>
              <span style={{ fontSize: 12, color: T.textSec, lineHeight: 1.5 }}><b style={{ color: T.text, fontWeight: 600 }}>A11y.</b> {a11y}</span>
            </div>
          )}
        </div>
      </div>
    </Card>
  );
}

// Small helper to wrap absolutely-positioned components in a relative stage.
function Stage({ w = 360, h = 92, bg = 'transparent', children }) {
  return <div style={{ position: 'relative', width: w, height: h, background: bg, borderRadius: 16 }}>{children}</div>;
}

function ButtonPreview() {
  return (
    <div style={{ width: 280, display: 'flex', flexDirection: 'column', gap: 9 }}>
      <Button variant="gold">Confirm pickup</Button>
      <div style={{ display: 'flex', gap: 9 }}>
        <Button variant="outline" size="sm">Outline</Button>
        <Button variant="outline-muted" size="sm">Muted</Button>
      </div>
      <Button variant="outline-draw" size="sm"><span className="mrt-gold-pulse">Request from Alex</span></Button>
      <Button variant="outline-static" size="sm">Continue</Button>
    </div>
  );
}

function ToggleRow() {
  const [a, setA] = cgS(true); const [b, setB] = cgS(false);
  return (
    <div style={{ display: 'flex', gap: 32, alignItems: 'center' }}>
      <Toggle value={a} onChange={setA} />
      <Toggle value={b} onChange={setB} />
    </div>
  );
}

function StatusRow() {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14, alignItems: 'flex-start' }}>
      <StatusBadge status="driving" /><StatusBadge status="parked" />
      <StatusBadge status="charging" /><StatusBadge status="offline" />
    </div>
  );
}

function NavPreview({ tabs, current }) {
  const [n, setN] = cgS(current);
  return (
    <Stage w={372} h={86} bg="#0b0b0d">
      <BottomNav current={n} onChange={setN} tabs={tabs} />
    </Stage>
  );
}

function DIPreview({ state }) {
  return (
    <Stage w={392} h={state === 'expanded' ? 150 : 70} bg="#000">
      <DynamicIsland state={state} vehicle="Cybercab" status="driving" eta={51} battery={68} speed={64} progress={0.42} />
    </Stage>
  );
}

function ControlTilePreview() {
  const [lock, setLock] = cgS(false);
  return (
    <div style={{ display: 'flex', gap: 8, width: 300 }}>
      <ControlTile icon={lock ? 'lock.open.fill' : 'lock.fill'} label={lock ? 'Unlocked' : 'Locked'} sub={lock ? 'Tap to lock' : 'Tap to unlock'} active={lock} activeColor={T.driving} onClick={() => setLock(l => !l)} />
      <ControlTile icon="fan" label="Climate" sub="On · 70°" active onClick={() => {}} />
      <ControlTile icon="bolt.fill" label="Charge" sub="Port closed" activeColor={T.charging} onClick={() => {}} />
    </div>
  );
}

function ChipPreview() {
  const [sel, setSel] = cgS('now');
  const S = useSurfaces();
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14, alignItems: 'center' }}>
      <div style={{ display: 'flex', gap: 3, padding: 3, borderRadius: 12, background: 'rgba(255,255,255,0.05)' }}>
        {[['now', 'Now'], ['sched', 'Schedule']].map(([k, l]) => (
          <button key={k} onClick={() => setSel(k)} style={{ padding: '7px 18px', borderRadius: 9, border: 'none', cursor: 'pointer', fontFamily: T.font, fontSize: 13, fontWeight: 600, background: sel === k ? T.gold : 'transparent', color: sel === k ? '#1a1408' : T.textSec }}>{l}</button>
        ))}
      </div>
      <div style={{ display: 'flex', gap: 8 }}>
        {['Date', 'Distance', 'Duration'].map((c, i) => (
          <div key={c} style={{ padding: '6px 13px', borderRadius: 99, fontSize: 12, fontWeight: 600, fontFamily: T.font, ...S.chip(i === 0) }}>{c}</div>
        ))}
      </div>
    </div>
  );
}

function CardRowPreview() {
  const d = { from: 'Home', to: 'Pescadero', start: '7:42 AM', miles: 28.4, mins: 92, fsd: 27.9 };
  return (
    <div style={{ width: 320 }}>
      <DriveRow d={d} onClick={() => {}} />
    </div>
  );
}

// ── Onboarding & overlay previews ────────────────────────────
function StepperPreview() {
  return <div style={{ position: 'relative', width: 320, height: 70 }}><div style={{ position: 'absolute', inset: 0 }}><PairStepper step={2} /></div></div>;
}
function SwitcherPreview() {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10 }}>
      <div style={{ display: 'inline-flex', alignItems: 'center', gap: 9, height: 40, padding: '0 8px 0 14px', borderRadius: 20, background: 'rgba(20,20,24,0.72)', border: `0.5px solid ${T.gold}77` }}>
        <SFIcon name="car.fill" size={16} color={T.gold} />
        <span style={{ fontSize: 15, fontWeight: 600, color: T.text }}>Cybercab</span>
        <span style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', width: 24, height: 24, borderRadius: 12, background: 'rgba(255,255,255,0.08)' }}><SFIcon name="chevron.down" size={12} color={T.textSec} /></span>
      </div>
      <div style={{ width: 220, borderRadius: 14, overflow: 'hidden', background: 'rgba(24,24,28,0.92)', border: '0.5px solid rgba(255,255,255,0.14)' }}>
        {[['Cybercab', 'RBO-2046', true], ['Daily', 'CTX-9417', false]].map(([n, p, on], i) => (
          <div key={n} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 13px', background: on ? `${T.gold}14` : 'transparent', borderTop: i ? '0.5px solid rgba(255,255,255,0.07)' : 'none' }}>
            <div style={{ width: 30, height: 30, borderRadius: 9, display: 'flex', alignItems: 'center', justifyContent: 'center', background: on ? `${T.gold}22` : 'rgba(255,255,255,0.06)' }}><SFIcon name="car.fill" size={15} color={on ? T.gold : T.textSec} /></div>
            <div style={{ flex: 1 }}><div style={{ fontSize: 13.5, fontWeight: 600, color: T.text }}>{n}</div><div style={{ fontSize: 11, color: T.textMuted }}>{p}</div></div>
            {on && <SFIcon name="checkmark" size={14} color={T.gold} weight={2.4} />}
          </div>
        ))}
      </div>
    </div>
  );
}
function DialogPreview() {
  return (
    <div style={{ width: 280, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, textAlign: 'center' }}>
      <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}><SFIcon name="person.fill" size={20} color="#FF6B6B" /></div>
      <div style={{ fontSize: 17, fontWeight: 600, color: T.text, marginBottom: 6 }}>Revoke access?</div>
      <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 18 }}><span style={{ color: T.text, fontWeight: 600 }}>Mira Chen</span> will no longer see your vehicle’s location or trips.</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
        <div style={{ padding: 13, borderRadius: 13, background: 'rgba(255,59,48,0.16)', color: '#FF6B6B', fontSize: 15, fontWeight: 600 }}>Revoke access</div>
        <div style={{ padding: 13, borderRadius: 13, border: `0.5px solid ${T.border}`, color: T.text, fontSize: 15, fontWeight: 500 }}>Keep access</div>
      </div>
    </div>
  );
}
function ToastPreview() {
  return (
    <div style={{ display: 'inline-flex', alignItems: 'center', gap: 10, padding: '13px 16px', borderRadius: 14, background: '#22221f', border: `0.5px solid ${T.gold}55` }}>
      <SFIcon name="checkmark" size={15} color={T.gold} weight={2.4} />
      <span style={{ fontSize: 13.5, color: T.text, fontWeight: 500 }}>Access revoked for Mira Chen</span>
    </div>
  );
}
function StoryDotsPreview() {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16 }}>
      <div style={{ width: 150, height: 60, borderRadius: 16, background: 'linear-gradient(160deg, rgba(34,34,40,0.9), rgba(16,16,20,0.92))', border: '0.5px solid rgba(255,255,255,0.10)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <SFIcon name="map.fill" size={22} color={T.gold} />
      </div>
      <div style={{ display: 'flex', gap: 7, alignItems: 'center' }}>
        <span style={{ width: 22, height: 7, borderRadius: 4, background: T.gold }} />
        {[0, 1, 2, 3].map(i => <span key={i} style={{ width: 7, height: 7, borderRadius: 4, background: 'rgba(255,255,255,0.2)' }} />)}
      </div>
    </div>
  );
}

function ComponentsSection() {
  return (
    <Section id="components" num="08" title="Components"
      intro="The reusable kit — every piece below is the live prototype component, not a redraw. Build each as a SwiftUI view with the listed props; honor the interaction and accessibility notes.">

      <Sub title="Actions">
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <ComponentDoc name="Button" tag="Button(variant:)" previewH={220}
            blurb="Six variants over a shared height ladder. Solid gold is the confirm/commit fill. The outline-draw variant — animated gold border trace + gold label — is reserved for the in-app request CTAs only. The outline-static variant is the calm gold-outline used for onboarding & tutorial buttons (same look, no animation)."
            preview={<ButtonPreview />}
            specs={[['Heights', 'sm 38 · md 46 · lg 52'], ['Radius', '12pt (flat) · h/2 (liquid)'], ['Gold fg', '#1a1408', true], ['Label', '15 / 600']]}
            interaction="Scale to 0.98 on press. outline-draw runs a 2.6s border trace + text pulse; outline-static is a static gold outline (reserve the trace for actionable ride CTAs)."
            a11y="Min target 44pt. Gold fill meets AA at 15pt. Provide an accessibilityLabel for icon-only buttons." />
          <ComponentDoc name="Toggle" tag="Toggle" previewH={120}
            blurb="iOS-standard switch; gold track when on."
            preview={<ToggleRow />}
            specs={[['Track', '51 × 31'], ['Knob', '27pt white'], ['On', 'Color.mrtGold', true], ['Off', 'mrtElevated']]}
            interaction="Knob slides 0.22s. Whole row is tappable in settings lists."
            a11y="Maps to native Toggle — VoiceOver reads on/off automatically." />
        </div>
      </Sub>

      <Sub title="Status & data">
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <ComponentDoc name="StatusBadge" tag="StatusBadge(status:)" previewH={170}
            blurb="A 6pt glowing dot + label. The dot color is the canonical signal for vehicle state across the app."
            preview={<StatusRow />}
            specs={[['Dot', '6pt + 6px glow'], ['driving', '#30D158', true], ['parked', '#3B82F6'], ['charging', '#FFD60A'], ['Label', '12 / 500 · text.sec']]}
            a11y="Pair color with the text label — never signal state by color alone." />
          <ComponentDoc name="TripProgressBar" tag="TripProgressBar(progress:)" wide previewH={120}
            blurb="The signature element — a gold fill with a glowing position orb on a 6pt track. Used in the sheet, Dynamic Island, widgets and Live Activity."
            preview={<div style={{ width: 360 }}><TripProgressBar progress={0.46} origin="Home" dest="Pescadero" /></div>}
            specs={[['Track', '6pt · mrtElevated'], ['Fill', 'Color.mrtGold', true], ['Orb', '15pt + 2pt white ring + glow'], ['Ease', 'width .8s cubic-bezier(.4,0,.2,1)']]}
            interaction="Orb + fill animate to new progress over 0.8s. Drives live ETA context." />
          <ComponentDoc name="BatteryBar" tag="BatteryBar(pct:)" previewH={140}
            blurb="Threshold-colored fill. Charging overrides to amber."
            preview={<div style={{ width: 280 }}><BatteryBar pct={68} showLabel /><div style={{ height: 14 }} /><BatteryBar pct={14} showLabel /></div>}
            specs={[['Height', '6pt (3pt in widgets)'], ['≥ 50%', '#30D158', true], ['20–49%', '#FFD60A'], ['< 20%', '#FF3B30'], ['Digits', 'monospaced']]}
            a11y="Expose pct as accessibilityValue; don’t rely on bar color alone." />
          <ComponentDoc name="Avatar" tag="Avatar(name:)" previewH={140}
            blurb="Initials on a name-hashed oklch fill; optional online dot."
            preview={<div style={{ display: 'flex', gap: 14, alignItems: 'center' }}><Avatar name="Mira Chen" size={44} online /><Avatar name="Jonas Park" size={44} /><Avatar name="Aanya Iyer" size={36} /></div>}
            specs={[['Fill', 'oklch(0.4 0.08 hash)'], ['Initials', 'size × 0.36'], ['Online', '#30D158 + bg ring', true]]} />
        </div>
      </Sub>

      <Sub title="Navigation & surfaces">
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <ComponentDoc name="BottomNav · Owner" tag="OWNER_TABS" wide previewH={120}
            blurb="Floating capsule tab bar. Four owner tabs; active tab in gold with the filled SF Symbol."
            preview={<NavPreview tabs={OWNER_TABS} current="home" />}
            specs={[['Tabs', 'Vehicle · Drives · Share · Settings'], ['Inset', '14pt sides · 26pt bottom'], ['Active', 'Color.mrtGold', true], ['Icon', '22pt · label 10/600']]}
            interaction="Tap switches tab; icons are .fill variants. Capsule floats over content."
            a11y="44pt targets. Use a TabView with custom tab bar; keep VoiceOver tab semantics." />
          <ComponentDoc name="BottomNav · Shared" tag="SHARED_TABS" wide previewH={120}
            blurb="The guest flow swaps to three tabs."
            preview={<NavPreview tabs={SHARED_TABS} current="shared" />}
            specs={[['Tabs', 'Live Map · Ride History · Settings'], ['Visible', 'idle + tracking only'], ['Hidden', 'while booking / pending']]} />
          <ComponentDoc name="ControlTile" tag="ControlTile" wide previewH={140}
            blurb="Square quick-control for the vehicle sheet. Active state tints to the control’s functional color."
            preview={<ControlTilePreview />}
            specs={[['Radius', '16pt'], ['Active border', 'color + 66 alpha'], ['Icon', '20pt'], ['Label', '13 / 600 · sub 11 / 500']]}
            interaction="Toggles state on tap; background + border animate 0.18s."
            a11y="Use accessibilityValue for on/off; 44pt min." />
          <ComponentDoc name="Segmented & chips" wide previewH={150}
            blurb="Gold-fill segmented control for binary modes; pill filter chips for sorts. Both read their style from useSurfaces()."
            preview={<ChipPreview />}
            specs={[['Segmented', 'gold fill · #1a1408 fg', true], ['Chip active', 'gold @ 22% + gold border'], ['Radius', '9pt seg · 99pt chip']]} />
          <ComponentDoc name="List card / row" tag="DriveRow" wide previewH={130}
            blurb="The elevated gold-tinted row used for drives, upcoming and ride history. Gradient wash + hairline gold border + soft drop."
            preview={<CardRowPreview />}
            specs={[['Radius', '16pt'], ['Wash', 'gold 10% → 3% → white 2%'], ['Border', '0.5pt gold @ 20%'], ['Title', '15 / 600 · route arrow gold']]}
            interaction="Whole row taps to detail; chevron in gold @ 55%." />
        </div>
      </Sub>

      <Sub title="Dynamic Island" hint="iPhone 14 Pro +">
        <Grid min={320}>
          <ComponentDoc name="Compact" tag="state: .compact" previewH={120} previewBg="dark"
            preview={<DIPreview state="compact" />}
            specs={[['Size', '126 × 37'], ['Leading', 'gold dot + status ring'], ['Trailing', 'ETA · monospaced', true]]} />
          <ComponentDoc name="Expanded" tag="state: .expanded" previewH={170} previewBg="dark"
            preview={<DIPreview state="expanded" />}
            specs={[['Size', '374 × 116–158'], ['Hero', 'ETA 30/300 gold', true], ['Footer', 'TripProgressBar'], ['Layouts', 'flighty · uber · detailed']]}
            interaction="Compact ↔ expanded morph 0.35s. Long-press → deep-link menu." />
        </Grid>
      </Sub>

      <Sub title="Onboarding & overlays" hint="Pairing · tutorials · confirmations">
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <ComponentDoc name="PairStepper" tag="AddTeslaFlow" wide previewH={130}
            blurb="4-step tracked progress for Tesla pairing. Done steps fill gold-deep with a check; the active step gets a ring + gold-deep-soft numeral; connectors fill as you advance."
            preview={<StepperPreview />}
            specs={[['Steps', 'Sign in · Linked · Virtual key · Paired'], ['Done/active', 'Color.mrtGoldDeep', true], ['Numeral/label', 'mrtGoldDeepSoft'], ['Node', '26pt · 1.5pt ring']]}
            interaction="Advances by pairing phase; stepper sits below the Cancel action." />
          <ComponentDoc name="Vehicle switcher" tag="MapHeader" previewH={150}
            blurb="Top-center capsule chip (car icon + vehicle name + chevron). Tap opens a picker menu listing each vehicle with plate + active check. Replaces the old page-dots (sub-44pt); collapses to a label when only one vehicle."
            preview={<SwitcherPreview />}
            specs={[['Chip', '40pt · glass'], ['Menu row', 'icon + name + plate'], ['Active', 'gold check + tint', true], ['Target', '≥ 44pt']]}
            interaction="iOS Menu / popover — avoid MKMapView pan conflict." />
          <ComponentDoc name="Confirmation dialog" tag="shared overlay" previewH={210}
            blurb="One reusable center-alert for every destructive/positive confirm: revoke, cancel invite, unlink Tesla, cancel reservation, sign out. Backdrop fade + card rise; tinted icon, subject-named body, stacked buttons."
            preview={<DialogPreview />}
            specs={[['Card', '#1a1a1c · r22 · max 300'], ['Destructive', 'rgba(255,59,48,.16) / #FF6B6B', true], ['Positive', 'gold fill'], ['Dismiss', 'outline-muted'], ['Motion', 'mrt-sched-up ~.28s']]}
            interaction="Backdrop or dismiss button closes; confirm mutates state + fires a toast." />
          <ComponentDoc name="Success toast" tag="shared overlay" wide previewH={110}
            blurb="Bottom-anchored confirmation after a mutation: access revoked, invite sent / resent. Gold checkmark + message; auto-dismisses."
            preview={<ToastPreview />}
            specs={[['Pill', '#22221f · gold hairline'], ['Icon', 'checkmark · gold', true], ['Anchor', 'above tab bar (bottom 116)'], ['Dismiss', 'auto ~2.8s']]} />
          <ComponentDoc name="Story card" tag="StoryDeck" wide previewH={130}
            blurb="Paged tutorial card (Things/Linear style): a floating hero vignette built from real app primitives, big title + body, page dots, outline-static CTA. Powers both the Owner and Rider tutorials."
            preview={<StoryDotsPreview />}
            specs={[['Slide', 'mrtStoryInL/R .45s'], ['Vignette', 'mrtVigFloat 4s bob'], ['Dots', 'active = gold 22×7'], ['CTA', 'outline-static · Skip top-right']]}
            interaction="Swipe or Continue; dots jump; last card fires onDone." />
        </div>
      </Sub>
    </Section>
  );
}

Object.assign(window, { ComponentsSection, ComponentDoc, Stage });
