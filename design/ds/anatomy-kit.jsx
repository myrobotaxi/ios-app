// MyRoboTaxi · Anatomy canvas — exploded-callout kit.
// Renders a target (screen or component) at natural size inside a board and
// draws leader lines from numbered anchors to spec labels around it.

const AMONO = 'ui-monospace, "SF Mono", "SFMono-Regular", Menlo, monospace';

// Context carrying the current Board's DOM node so Notes can resolve anchors
// from live element positions instead of hardcoded coordinates.
const AnatomyBoardCtx = React.createContext(null);

// Position of an element relative to a board ancestor, in the board's layout
// space (matches the SVG coordinate space). Uses bounding rects normalized by
// the board's render scale, so it's correct under any canvas pan/zoom.
function relAnchor(el, boardEl, anchor = 'center') {
  if (!el || !boardEl) return null;
  const br = boardEl.getBoundingClientRect();
  const r = el.getBoundingClientRect();
  if (!r.width && !r.height) return null;
  const scale = (br.width / boardEl.offsetWidth) || 1;
  const x = (r.left - br.left) / scale, y = (r.top - br.top) / scale;
  const ew = r.width / scale, eh = r.height / scale;
  const ax = anchor.includes('l') ? x : anchor.includes('r') ? x + ew : x + ew / 2;
  const ay = anchor.includes('t') ? y : anchor.includes('b') ? y + eh : y + eh / 2;
  return [Math.round(ax), Math.round(ay)];
}

// Finder factories for the `find` prop. Self-heal when the UI moves.
function byText(t) {
  return (board) => [...board.querySelectorAll('div,span,button')].find(
    (e) => e.children.length === 0 && e.textContent.trim().startsWith(t));
}
function byAll(sel, i = 0) { return (board) => board.querySelectorAll(sel)[i]; }

// Board background filling a DCArtboard. Dark app surface + faint grid.
// Publishes its DOM node so child Notes can resolve live anchors.
function Board({ w, h, children, pad = 0 }) {
  const [node, setNode] = React.useState(null);
  return (
    <AnatomyBoardCtx.Provider value={node}>
    <div ref={(el) => { if (el && el !== node) setNode(el); }} style={{
      position: 'relative', width: w, height: h, overflow: 'hidden',
      background: '#0c0c0e', color: T.text, fontFamily: T.font,
      backgroundImage: 'radial-gradient(circle at 50% 30%, rgba(201,168,76,0.05), transparent 60%), linear-gradient(rgba(255,255,255,0.022) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.022) 1px, transparent 1px)',
      backgroundSize: 'auto, 32px 32px, 32px 32px',
    }}>{children}</div>
    </AnatomyBoardCtx.Provider>
  );
}

// A phone screen host at natural 402×874. Anchor coords map 1:1 to layout.
function ScreenHost({ x, y, di, children, scale = 1 }) {
  const W = 402, H = 874;
  return (
    <div style={{ position: 'absolute', left: x, top: y, width: W * scale, height: H * scale }}>
      <div style={{
        position: 'absolute', top: 0, left: 0, width: W, height: H,
        transform: `scale(${scale})`, transformOrigin: 'top left',
        borderRadius: 46, overflow: 'hidden', background: '#000',
        border: '5px solid #1b1b1e', boxShadow: '0 30px 80px rgba(0,0,0,0.55)',
      }}>
        <div style={{ position: 'absolute', inset: 0, overflow: 'hidden' }}>
          {children}
          <PhoneStatusBar />
          {di || <DynamicIsland state="minimal" />}
          <div style={{ position: 'absolute', bottom: 8, left: 0, right: 0, display: 'flex', justifyContent: 'center', zIndex: 100, pointerEvents: 'none' }}>
            <div style={{ width: 139, height: 5, borderRadius: 99, background: 'rgba(255,255,255,0.5)' }} />
          </div>
        </div>
      </div>
    </div>
  );
}

// A bare component host (no phone chrome) centered at (x,y) with given size.
function PartHost({ x, y, w, h, bg = '#070707', label, children, rounded = 16 }) {
  return (
    <div style={{ position: 'absolute', left: x, top: y, width: w, height: h }}>
      <div style={{
        width: '100%', height: '100%', borderRadius: rounded, overflow: 'visible',
        background: bg, border: `0.5px solid ${T.border}`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        boxShadow: '0 18px 50px rgba(0,0,0,0.4)',
      }}>{children}</div>
      {label && <div style={{ position: 'absolute', top: -22, left: 2, fontSize: 10.5, letterSpacing: 1, textTransform: 'uppercase', color: T.textMuted, fontWeight: 600 }}>{label}</div>}
    </div>
  );
}

// ── Note: leader line from anchor (ax,ay) to a label box at (tx,ty) ──
// side: 'l' (label left of anchor) | 'r' (label right of anchor).
// Pass `find` (a finder, e.g. byText('Driving')) to resolve the anchor from
// the live element — it self-corrects when the UI moves. ax/ay are the
// fallback used until/unless the element is found.
function Note({ ax, ay, tx, ty, w = 188, n, title, lines = [], side = 'r', color = T.gold, find, anchor = 'center' }) {
  const boardEl = React.useContext(AnatomyBoardCtx);
  const [pt, setPt] = React.useState(null);
  React.useLayoutEffect(() => {
    if (!find || !boardEl) return;
    let alive = true;
    const compute = () => { if (!alive) return; const el = find(boardEl); if (el) { const p = relAnchor(el, boardEl, anchor); if (p) setPt(p); } };
    compute();
    const ro = new ResizeObserver(compute); ro.observe(boardEl);
    const t1 = setTimeout(compute, 360); const t2 = setTimeout(compute, 1100);
    return () => { alive = false; ro.disconnect(); clearTimeout(t1); clearTimeout(t2); };
  }, [find, boardEl, anchor]);
  const AX = pt ? pt[0] : ax, AY = pt ? pt[1] : ay;
  if (AX == null || AY == null) return null;
  const connY = ty + 17;
  const connX = side === 'l' ? tx + w : tx;
  return (
    <>
      {/* Leader line + anchor */}
      <svg style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', pointerEvents: 'none', zIndex: 6 }} width="100%" height="100%">
        <line x1={connX} y1={connY} x2={AX} y2={AY} stroke={color} strokeOpacity="0.55" strokeWidth="1" strokeDasharray="1 0" />
        <circle cx={connX} cy={connY} r="2.5" fill={color} />
        <circle cx={AX} cy={AY} r="6.5" fill="none" stroke={color} strokeOpacity="0.5" strokeWidth="1" />
        <circle cx={AX} cy={AY} r="3" fill={color} />
      </svg>
      {/* Label */}
      <div style={{
        position: 'absolute', left: tx, top: ty, width: w, zIndex: 7,
        background: 'rgba(16,16,19,0.94)', border: `0.5px solid ${color}55`,
        borderRadius: 11, padding: '11px 13px',
        boxShadow: '0 10px 28px rgba(0,0,0,0.5)', backdropFilter: 'blur(8px)',
      }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 7, marginBottom: lines.length ? 7 : 0 }}>
          {n != null && (
            <span style={{ flexShrink: 0, width: 16, height: 16, borderRadius: 8, background: color, color: '#1a1408', fontFamily: AMONO, fontSize: 10, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{n}</span>
          )}
          <span style={{ fontSize: 13, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>{title}</span>
        </div>
        {lines.map((l, i) => (
          <div key={i} style={{ display: 'flex', gap: 6, marginTop: i ? 4 : 0, alignItems: 'baseline' }}>
            <span style={{ flexShrink: 0, color: color, opacity: 0.7, fontSize: 10, marginTop: 1 }}>·</span>
            <span style={{ fontFamily: l.mono === false ? T.font : AMONO, fontSize: 11, color: l.gold ? color : T.textSec, lineHeight: 1.4, letterSpacing: -0.1 }}>{l.t || l}</span>
          </div>
        ))}
      </div>
    </>
  );
}

// Board caption — title + sub, top-left of a board.
function BoardCap({ title, sub, kicker }) {
  return (
    <div style={{ position: 'absolute', top: 26, left: 30, zIndex: 8, maxWidth: 280 }}>
      {kicker && <div style={{ fontSize: 10.5, letterSpacing: 1.4, textTransform: 'uppercase', color: T.gold, fontWeight: 700, marginBottom: 8 }}>{kicker}</div>}
      <div style={{ fontSize: 23, fontWeight: 600, color: T.text, letterSpacing: -0.5, lineHeight: 1.1 }}>{title}</div>
      {sub && <div style={{ fontSize: 13, color: T.textSec, marginTop: 8, lineHeight: 1.5 }}>{sub}</div>}
    </div>
  );
}

Object.assign(window, { Board, ScreenHost, PartHost, Note, BoardCap, ANATOMY_MONO: AMONO, byText, byAll, relAnchor });
