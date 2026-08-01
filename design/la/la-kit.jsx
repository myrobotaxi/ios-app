// Live Activity + Dynamic Island surfaces. (v3)
//
// Layout follows the Uber ride Live Activity: wordmark row, a bold ETA-led
// headline with a place under it and an identifying tile trailing, then the
// route line across the bottom. Every Lock Screen card is the SAME size in
// every state — 350 × 128 — with fixed-height rows.
//
//   1  wordmark row   logo + wordmark                              20
//   2  headline       bold, leads: "Pickup in 8 min" / "3:42 PM…"  24
//   3  subline        plate + car, or "Heading to …"               17
//   4  route line     always drawn, car puck + destination pin     18

const LA_CARD_W = 350;
const LA_CARD_H = 128;

// The brand facet arrow, banked to point due east — the direction of travel
// on the rail. Fixed rotation; never re-rotated per progress.
function LAArrowEast({ size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" style={{ display: 'block', flexShrink: 0 }}>
      <g transform="rotate(90 50 50)">
        <polygon points="50,12 50,64 18,85" fill="#E4D08A" />
        <polygon points="50,12 82,85 50,64" fill="#9C7E2C" />
      </g>
    </svg>
  );
}

// The card ground — the logo tile's backdrop: warm brown-black with a gold
// bloom from the top-left. Opaque, so it never picks up the wallpaper.
const LA_GROUND = 'radial-gradient(120% 130% at 14% -20%, rgba(201,168,76,0.13), rgba(201,168,76,0) 58%), linear-gradient(155deg, #1b1407 0%, #0d0b06 55%, #090806 100%)';

// ── Compact glyphs ───────────────────────────────────────────
// Real production icons, not hand-drawn paths: Material Symbols Rounded
// (Apache-2.0) rendered as ligature glyphs, filled, tinted gold. Uber swaps in
// a waving-driver glyph the moment the car is at the curb; ours waves too, and
// a check closes the ride out. On device these are the SF Symbol equivalents —
// hand.wave.fill and checkmark.circle.fill — same shapes, Apple's optical
// weights, so nothing here is bespoke artwork the engineer has to redraw.
const LA_GLYPHS = { wave: 'waving_hand', check: 'check_circle' };

function LAGlyph({ kind, size = 19 }) {
  return (
    <span className="msym" style={{ fontSize: size, color: '#fff', flexShrink: 0 }}>
      {LA_GLYPHS[kind] || LA_GLYPHS.wave}
    </span>
  );
}

// ── Route line ───────────────────────────────────────────────
// ALWAYS RENDERED, and always gold. Track, gold fill, the brand arrow riding
// the head as the vehicle puck, and a destination pin at the end. Unlabeled —
// the subline already names where you're going. At 100% the pin is removed and
// the mark takes its place: the car IS the destination marker once it arrives.
// The only other variant is 'idle': a route that exists but is untraveled.
function LARail({ p = 0, state = 'live', h = 5 }) {
  const idle = state === 'idle';
  const done = p >= 0.999;
  return (
    <div style={{ position: 'relative', width: '100%', height: 18, display: 'flex', alignItems: 'center' }}>
      <div style={{ position: 'absolute', left: 0, right: 0, height: h, borderRadius: h / 2,
        background: 'rgba(255,255,255,0.13)', boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.07)' }} />
      {!idle && <div style={{ position: 'absolute', left: 0, width: `${p * 100}%`, height: h, borderRadius: h / 2,
        background: T.gold, transition: 'width .5s cubic-bezier(.2,.8,.2,1)' }} />}
      <div style={{ position: 'absolute', left: `calc(11px + (100% - 22px) * ${p})`, transform: 'translateX(-50%)', width: 22, height: 22,
        borderRadius: 11, background: '#0d0b06', boxShadow: '0 0 0 2px #0d0b06', display: 'flex', alignItems: 'center',
        justifyContent: 'center', transition: 'left .5s cubic-bezier(.2,.8,.2,1)', opacity: idle ? 0.5 : 1 }}>
        <LAArrowEast size={14} />
      </div>
      {/* the pin is the destination marker until the car gets there — at which
         point the mark itself IS the marker, so the pin steps aside */}
      {!done && <div style={{ position: 'absolute', right: 0, width: 11, height: 11, borderRadius: 6, boxSizing: 'border-box',
        border: '2px solid rgba(255,255,255,0.32)', background: '#0d0b06' }} />}
    </div>
  );
}

// ── Headline ─────────────────────────────────────────────────
// Bold, leads the card, one line, one size. Three forms:
//   phase  "Pickup in 8 min"   — a countdown, pickup leg only
//   clock  "3:42 PM dropoff"   — a time of day, trip leg only
//   status "Pickup soon"       — same slot when there is no number
function LAHeadline({ h, size = 20 }) {
  const base = { fontSize: size, fontWeight: 600, color: '#fff', letterSpacing: -0.45, lineHeight: 1 };
  const soft = { ...base, fontWeight: 500, color: 'rgba(255,255,255,0.62)' };
  const num = { ...base, fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums' };
  return (
    <div style={{ height: 24, display: 'flex', alignItems: 'center', gap: 5, whiteSpace: 'nowrap', minWidth: 0 }}>
      {h.phase && <><span style={base}>{h.phase}</span><span style={soft}>in</span><span style={num}>{h.value}</span><span style={soft}>{h.unit}</span></>}
      {h.clock && <><span style={num}>{h.clock}</span><span style={soft}>{h.word}</span></>}
      {h.status && <span style={{ ...base, overflow: 'hidden', textOverflow: 'ellipsis' }}>{h.status}</span>}
    </div>
  );
}

function LASub({ children, size = 13.5 }) {
  return <div style={{ height: 17, display: 'flex', alignItems: 'center', fontSize: size, fontWeight: 400,
    color: 'rgba(255,255,255,0.58)', letterSpacing: -0.1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{children}</div>;
}

// ── Lock Screen card ─────────────────────────────────────────
// Fixed 350 × 128 in every single state.
function LALockCard({ s, w = LA_CARD_W, h = LA_CARD_H }) {
  return (
    <div style={{ width: w, height: h, borderRadius: 22, padding: '12px 15px 13px', boxSizing: 'border-box',
      background: LA_GROUND, border: '0.5px solid rgba(201,168,76,0.16)', boxShadow: '0 14px 38px rgba(0,0,0,0.55)',
      fontFamily: T.font, color: '#fff', display: 'flex', flexDirection: 'column', justifyContent: 'space-between' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, height: 20 }}>
        <HexLogo size={20} />
        <span style={{ fontSize: 10, fontWeight: 500, letterSpacing: 0.9, textTransform: 'uppercase',
          color: 'rgba(255,255,255,0.42)', flex: 1, minWidth: 0 }}>myrobotaxi</span>
      </div>
      <div>
        <LAHeadline h={s.headline} />
        <LASub>{s.sub}</LASub>
      </div>
      <LARail p={s.rail.p} state={s.rail.state} />
    </div>
  );
}

// ── Dynamic Island ───────────────────────────────────────────
function LAIslandMinimal() {
  return (
    <div style={{ width: 37, height: 37, borderRadius: 19, background: '#000', display: 'flex',
      alignItems: 'center', justifyContent: 'center' }}>
      <LAArrowEast size={17} />
    </div>
  );
}

// Mark leading, figure trailing — Uber's compact shape, and only ever a
// figure: "8 min" · "1 min" · "3:42 PM". Where Uber has no figure it shows
// the mark alone (Dispatch) or
// rail's own arrival pin as the glyph.
function LAIslandCompact({ s }) {
  const { text, glyph } = s.compact;
  const bare = !text && !glyph;
  return (
    <div style={{ height: 37, minWidth: bare ? 74 : glyph ? 92 : 126, padding: bare ? '0 14px' : '0 13px 0 11px',
      borderRadius: 19, background: '#000', display: 'inline-flex', alignItems: 'center',
      justifyContent: bare ? 'center' : 'flex-start', gap: 9, fontFamily: T.font }}>
      <LAArrowEast size={16} />
      {text && <span style={{ fontFamily: T.fontNum, fontSize: 15, fontWeight: 600, color: '#fff',
        fontVariantNumeric: 'tabular-nums', letterSpacing: -0.2, whiteSpace: 'nowrap' }}>{text}</span>}
      {glyph && <LAGlyph kind={glyph} />}
    </div>
  );
}

// Expanded: the card's own middle and bottom rows, nothing else. Sized to
// its content — 372 × 96 — instead of leaving a field of black.
function LAIslandExpanded({ s, w = 372 }) {
  return (
    <div style={{ width: w, borderRadius: 38, padding: '12px 18px 14px', boxSizing: 'border-box', background: '#000',
      fontFamily: T.font, color: '#fff', display: 'flex', flexDirection: 'column', gap: 9 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
        <HexLogo size={28} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <LAHeadline h={s.headline} size={19} />
          <LASub size={12.5}>{s.sub}</LASub>
        </div>
      </div>
      <LARail p={s.rail.p} state={s.rail.state} />
    </div>
  );
}

// ── Frames ───────────────────────────────────────────────────
function LAIslandFrame({ children, w = 372, label }) {
  return (
    <div style={{ width: w + 24, borderRadius: 40, padding: '12px 12px 14px', background: 'linear-gradient(180deg,#232326,#131315)',
      boxShadow: '0 18px 40px rgba(0,0,0,0.5), inset 0 0 0 1px rgba(255,255,255,0.05)' }}>
      <div style={{ display: 'flex', justifyContent: 'center' }}>{children}</div>
      {label && <div style={{ textAlign: 'center', marginTop: 12, fontSize: 10, letterSpacing: 1.1, textTransform: 'uppercase',
        color: T.textMuted, fontFamily: T.font, fontWeight: 500 }}>{label}</div>}
    </div>
  );
}

function LAWallpaper({ children, w = 372, h = 620, clock = true }) {
  return (
    <div style={{ width: w, height: h, borderRadius: 46, overflow: 'hidden', position: 'relative', fontFamily: T.font,
      background: 'radial-gradient(120% 80% at 25% 12%, #241a10 0%, #100d0a 45%, #06060a 100%)',
      boxShadow: '0 28px 60px rgba(0,0,0,0.55), inset 0 0 0 1px rgba(255,255,255,0.05)' }}>
      {clock && (
        <div style={{ position: 'absolute', top: 62, left: 0, right: 0, textAlign: 'center' }}>
          <div style={{ fontSize: 15, color: 'rgba(255,255,255,0.72)' }}>Saturday, August 1</div>
          <div style={{ fontSize: 84, fontWeight: 200, lineHeight: 1.05, letterSpacing: -3, color: '#fff' }}>3:31</div>
        </div>
      )}
      {children}
    </div>
  );
}

function LANote({ children, w = LA_CARD_W }) {
  return <div style={{ width: w, fontFamily: T.font, fontSize: 11.5, lineHeight: 1.5, color: T.textMuted, textWrap: 'pretty' }}>{children}</div>;
}

Object.assign(window, { LAArrowEast, LAGlyph, LA_GROUND, LA_CARD_W, LA_CARD_H, LARail, LAHeadline, LASub,
  LALockCard, LAIslandMinimal, LAIslandCompact, LAIslandExpanded, LAIslandFrame, LAWallpaper, LANote });
