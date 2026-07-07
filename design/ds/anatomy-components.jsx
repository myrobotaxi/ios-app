// MyRoboTaxi · Anatomy canvas — exploded COMPONENT boards.
// Components render in isolation at known positions, so leader-line anchors
// are exact.

const { useState: acS } = React;

// Black device-style box (for Dynamic Island).
function DIBox({ x, y, w, h, children }) {
  return (
    <div style={{ position: 'absolute', left: x, top: y, width: w, height: h, background: '#000', borderRadius: 26, border: '0.5px solid #222', overflow: 'visible' }}>{children}</div>
  );
}

// ── TripProgressBar anatomy ──────────────────────────────────
function BoardTripBar() {
  const w = 340, px = 250, py = 250;
  const orbX = px + 0.46 * w;       // progress orb x
  const trackY = py + 7;            // track centre
  return (
    <Board w={840} h={520}>
      <BoardCap kicker="Signature component" title="TripProgressBar"
        sub="Used in the sheet, Dynamic Island, widgets and Live Activity. One gold fill, one glowing position orb." />
      <div style={{ position: 'absolute', left: px, top: py, width: w }}>
        <TripProgressBar progress={0.46} origin="Home" dest="Pescadero" />
      </div>
      <Note n="1" {...{ tx: 60, ty: 90, w: 200 }} ax={px + 0.23 * w} ay={trackY} title="Travelled"
        lines={[{ t: 'mrtGold fill · 6pt', gold: true }, { t: 'rounded caps' }]} />
      <Note n="2" {...{ tx: 60, ty: 360, w: 200 }} ax={px + 0.72 * w} ay={trackY} title="Remaining track"
        lines={[{ t: 'mrtElevated #2A2A2A' }, { t: 'full-width pill' }]} />
      <Note n="3" side="l" {...{ tx: 580, ty: 90, w: 200 }} ax={orbX} ay={trackY} title="Position orb"
        lines={[{ t: '15pt + 2pt white ring' }, { t: 'gold glow halo', gold: true }, { t: 'animates .8s' }]} />
      <Note n="4" side="l" {...{ tx: 580, ty: 360, w: 200 }} find={byText('Pescadero')} ax={px + w - 30} ay={py + 32} title="End captions"
        lines={[{ t: 'origin / dest' }, { t: '12pt text.muted' }]} />
    </Board>
  );
}

// ── Dynamic Island anatomy ───────────────────────────────────
function BoardDI() {
  return (
    <Board w={900} h={560}>
      <BoardCap kicker="iPhone 14 Pro +" title="Dynamic Island"
        sub="Compact persists during a drive; expanded morphs on tap. Three expanded layouts ship: flighty · uber · detailed." />
      {/* Compact */}
      <DIBox x={120} y={150} w={300} h={120}>
        <DynamicIsland state="compact" vehicle="Cybercab" status="driving" eta={51} battery={68} speed={64} progress={0.46} />
      </DIBox>
      {/* Expanded */}
      <DIBox x={120} y={330} w={430} h={170}>
        <DynamicIsland state="expanded" expandedStyle="flighty" vehicle="Cybercab" status="driving" eta={51} battery={68} speed={64} progress={0.46} />
      </DIBox>

      <Note n="1" side="l" {...{ tx: 620, ty: 120, w: 220 }} ax={120 + 26} ay={150 + 60} title="Leading · status"
        lines={[{ t: 'gold dot + status ring' }, { t: 'ring = drive/charge/park' }]} />
      <Note n="2" side="l" {...{ tx: 620, ty: 250, w: 220 }} ax={120 + 300 - 30} ay={150 + 60} title="Trailing · ETA"
        lines={[{ t: 'mins · monospacedDigit', gold: true }, { t: '13/600' }]} />
      <Note n="3" side="l" {...{ tx: 620, ty: 360, w: 220 }} ax={120 + 215 / 2} ay={330 + 64} title="Expanded hero"
        lines={[{ t: 'ETA 30/300 gold', gold: true }, { t: 'speed · battery pair' }]} />
      <Note n="4" side="l" {...{ tx: 620, ty: 470, w: 220 }} ax={120 + 215} ay={330 + 150} title="Footer bar"
        lines={[{ t: 'TripProgressBar' }, { t: 'Home → Pescadero' }]} />
    </Board>
  );
}

// ── BottomNav anatomy ────────────────────────────────────────
function BoardNav() {
  const [n, setN] = acS('home');
  const navX = 230, navY = 240, navW = 372;
  return (
    <Board w={840} h={460}>
      <BoardCap kicker="Navigation" title="Floating Tab Bar"
        sub="Detached capsule over content. Active tab in gold with the .fill SF Symbol; 44pt targets." />
      <div style={{ position: 'absolute', left: navX, top: navY, width: navW, height: 92, background: '#0b0b0d', borderRadius: 18 }}>
        <BottomNav current={n} onChange={setN} tabs={OWNER_TABS} />
      </div>
      {/* nav inner bar: left/right inset 14, bottom 26, height 60 → top ~ navY+? our box is 92 tall, BottomNav uses bottom:26 → sits low. */}
      <Note n="1" {...{ tx: 60, ty: 110, w: 200 }} find={byText('Vehicle')} ax={navX + 14 + 44} ay={navY + 56} title="Active tab"
        lines={[{ t: 'icon gold + filled', gold: true }, { t: 'label 10/600' }]} />
      <Note n="2" {...{ tx: 60, ty: 300, w: 200 }} find={byText('Drives')} ax={navX + navW / 2} ay={navY + 56} title="Inactive tab"
        lines={[{ t: 'white @ 42%' }, { t: 'icon 22pt' }]} />
      <Note n="3" side="l" {...{ tx: 600, ty: 110, w: 200 }} ax={navX + navW - 30} ay={navY + 30} title="Capsule"
        lines={[{ t: 'inset 14pt sides' }, { t: 'blur + 0.5pt rim' }, { t: 'drop shadow' }]} />
    </Board>
  );
}

// ── Button anatomy ───────────────────────────────────────────
function BoardButton() {
  const bx = 290, bw = 260, byG = 196, byD = 262;
  return (
    <Board w={840} h={460}>
      <BoardCap kicker="Action" title="Button"
        sub="Two primary shapes: the solid-gold fill for confirm/commit actions, and the outline-draw trace reserved for the request CTA. Near-black label on gold; gold label on the trace." />
      <div style={{ position: 'absolute', left: bx, top: byG, width: bw }}>
        <Button variant="gold">Confirm pickup</Button>
      </div>
      <div style={{ position: 'absolute', left: bx, top: byD, width: bw }}>
        <Button variant="outline-draw"><span className="mrt-gold-pulse">Request from Alex</span></Button>
      </div>
      <Note n="1" {...{ tx: 60, ty: 110, w: 200 }} ax={bx + 30} ay={byG + 23} title="Gold fill"
        lines={[{ t: 'Color.mrtGold', gold: true }, { t: 'Done · Confirm · Add' }, { t: 'label 15/600 · #1a1408' }]} />
      <Note n="2" {...{ tx: 60, ty: 330, w: 210 }} find={byText('Request from Alex')} ax={bx + bw / 2} ay={byD + 23} title="Request CTA"
        lines={[{ t: 'outline-draw variant', gold: true }, { t: '2.6s gold border trace' }, { t: 'gold label · pulse' }]} />
      <Note n="3" side="l" {...{ tx: 590, ty: 110, w: 200 }} ax={bx + bw - 20} ay={byG + 2} title="Height ladder"
        lines={[{ t: 'sm 38 · md 46 · lg 52' }, { t: 'min target 44pt' }]} />
      <Note n="4" side="l" {...{ tx: 590, ty: 330, w: 200 }} ax={bx + bw - 6} ay={byD + 40} title="Radius"
        lines={[{ t: '12pt flat' }, { t: 'h/2 pill in liquid' }]} />
    </Board>
  );
}

// ── ControlTile + DriveRow anatomy ───────────────────────────
function BoardCards() {
  const tileX = 150, tileY = 220;
  const rowX = 470, rowY = 220, rowW = 320;
  return (
    <Board w={900} h={520}>
      <BoardCap kicker="Surfaces" title="Tiles & rows"
        sub="The two repeating container shapes: a square quick-control tile and the elevated gold-wash list row." />
      {/* ControlTile (single) */}
      <div style={{ position: 'absolute', left: tileX, top: tileY, width: 150 }}>
        <DesignCtx.Provider value="flat">
          <ControlTile icon="lock.fill" label="Locked" sub="Tap to unlock" active={false} onClick={() => {}} />
        </DesignCtx.Provider>
      </div>
      {/* DriveRow */}
      <div style={{ position: 'absolute', left: rowX, top: rowY, width: rowW }}>
        <DriveRow d={{ from: 'Home', to: 'Pescadero', start: '7:42 AM', miles: 28.4, mins: 92, fsd: 27.9 }} onClick={() => {}} />
      </div>
      <Note n="1" {...{ tx: 40, ty: 110, w: 190 }} ax={tileX + 26} ay={tileY + 30} title="Icon"
        lines={[{ t: '20pt · functional color' }]} />
      <Note n="2" {...{ tx: 40, ty: 360, w: 190 }} find={byText('Locked')} ax={tileX + 75} ay={tileY + 95} title="Label + sub"
        lines={[{ t: '13/600 · sub 11/500' }, { t: 'active → color tint', gold: true }]} />
      <Note n="3" side="l" {...{ tx: 700, ty: 130, w: 190 }} ax={rowX + rowW - 24} ay={rowY + 30} title="Disclosure"
        lines={[{ t: 'chevron gold @ 55%' }]} />
      <Note n="4" side="l" {...{ tx: 700, ty: 330, w: 190 }} ax={rowX + 90} ay={rowY + 30} title="Route title"
        lines={[{ t: '15/600 · arrow gold', gold: true }, { t: 'gold-wash card 16pt' }]} />
      <Note n="5" {...{ tx: 360, ty: 410, w: 200 }} ax={rowX + 90} ay={rowY + 56} title="Trip stats"
        lines={[{ t: 'mi · min · FSD %' }, { t: 'tabular numerals' }]} />
    </Board>
  );
}

Object.assign(window, { BoardTripBar, BoardDI, BoardNav, BoardButton, BoardCards });
