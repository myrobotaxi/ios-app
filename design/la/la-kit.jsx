// Live Activity + Dynamic Island surfaces.
// Every surface is built from the same five parts: brand tile, headline,
// second line, progress rail, status chip (+ stale notice).

const { useState: laS, useEffect: laE } = React;

// The brand facet arrow, banked to point due east — the direction of travel
// on the rail. Same two facets as the mark, never re-rotated per progress.
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

// ── Progress rail ────────────────────────────────────────────
// Elevated track; gold fill; the brand facet arrow rides the head,
// never rotated along the rail. Absent progress = no rail at all.
function LARail({ p = 0, leg = 1, dim = false, width = '100%', h = 5 }) {
  const fill = dim ? '#5C5A54' : T.gold;
  const capOn = dim ? '#5C5A54' : (leg === 2 ? T.gold : T.goldDeepSoft);
  return (
    <div style={{ position: 'relative', width, height: 18, display: 'flex', alignItems: 'center' }}>
      <div style={{ position: 'absolute', left: 0, right: 0, height: h, borderRadius: h / 2,
        background: 'rgba(255,255,255,0.13)', boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.07)' }} />
      <div style={{ position: 'absolute', left: 0, width: `calc(${p * 100}% )`, height: h, borderRadius: h / 2,
        background: fill, transition: 'width .5s cubic-bezier(.2,.8,.2,1)' }} />
      <div style={{ position: 'absolute', right: 0, width: h, height: h, borderRadius: h / 2, background: capOn, opacity: p >= 1 ? 1 : 0.55 }} />
      <div style={{ position: 'absolute', left: `${p * 100}%`, transform: 'translateX(-50%)', width: 20, height: 20,
        borderRadius: 10, background: '#0d0b06', display: 'flex', alignItems: 'center', justifyContent: 'center',
        transition: 'left .5s cubic-bezier(.2,.8,.2,1)', opacity: dim ? 0.55 : 1 }}>
        <LAArrowEast size={13} />
      </div>
    </div>
  );
}

// ── Status chip ──────────────────────────────────────────────
function LAChip({ label, tone = 'active', pulse = false, size = 10.5 }) {
  const c = (LA_TONE[tone] || LA_TONE.active).c;
  return (
    <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, height: 20, padding: '0 8px 0 7px',
      borderRadius: 10, background: 'rgba(255,255,255,0.07)', border: '0.5px solid rgba(255,255,255,0.10)',
      fontFamily: T.font, whiteSpace: 'nowrap', flexShrink: 0 }}>
      <span style={{ width: 5, height: 5, borderRadius: 3, background: c, flexShrink: 0,
        animation: pulse ? 'laPulse 1.6s ease-in-out infinite' : undefined }} />
      <span style={{ fontSize: size, fontWeight: 500, letterSpacing: 0.2, color: 'rgba(255,255,255,0.82)' }}>{label}</span>
    </div>
  );
}

// ── Headline ─────────────────────────────────────────────────
function LAHeadline({ h, size = 17.5 }) {
  if (h.kind === 'countdown') {
    // One type size across the whole line; the unit does the disambiguating
    // so a duration can never be misread as a clock time.
    return (
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 6, minWidth: 0, whiteSpace: 'nowrap' }}>
        <span style={{ fontSize: size, fontWeight: 500, color: 'rgba(255,255,255,0.62)', letterSpacing: -0.2 }}>{h.prefix}</span>
        <span style={{ fontFamily: T.fontNum, fontSize: size, fontWeight: 600, color: '#fff',
          fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3 }}>{h.value}</span>
        <span style={{ fontSize: size, fontWeight: 500, color: 'rgba(255,255,255,0.62)', letterSpacing: -0.2 }}>{h.unit}</span>
      </div>
    );
  }
  return <div style={{ fontSize: size, fontWeight: 500, color: '#fff', letterSpacing: -0.3, lineHeight: 1.25, textWrap: 'pretty' }}>{h.text}</div>;
}

// Second line — one place, never a pair. Leg 1 names where you meet the car;
// leg 2 names where you're going, in gold. The headline says which leg it is.
function LASecond({ second, size = 13.5 }) {
  if (!second) return null;
  const dest = !!second.trip;
  const text = dest ? LA_DEST : (second.pickup ? LA_PICKUP : second);
  return <div style={{ fontSize: size, color: dest ? T.gold : 'rgba(255,255,255,0.62)', letterSpacing: -0.1,
    overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{text}</div>;
}

// ── Lock Screen / banner card ────────────────────────────────
function LALockCard({ s, width = 350 }) {
  return (
    <div style={{ width, borderRadius: 22, padding: '13px 15px 14px', boxSizing: 'border-box',
      background: LA_GROUND,
      border: '0.5px solid rgba(201,168,76,0.16)', boxShadow: '0 14px 38px rgba(0,0,0,0.55)',
      fontFamily: T.font, color: '#fff', display: 'flex', flexDirection: 'column', gap: 10 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <HexLogo size={20} />
        <span style={{ fontSize: 10, fontWeight: 500, letterSpacing: 0.9, textTransform: 'uppercase',
          color: 'rgba(255,255,255,0.42)', flex: 1, minWidth: 0 }}>myrobotaxi</span>
        <LAChip label={s.chip} tone={s.tone} pulse={s.pulse} />
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
        <LAHeadline h={s.headline} />
        <LASecond second={s.second} />
      </div>
      {s.track && <LARail p={s.track.p} leg={s.track.leg} dim={!!s.stale} />}
      {s.stale && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 11.5, color: 'rgba(255,255,255,0.42)', letterSpacing: -0.05 }}>
          <span style={{ width: 5, height: 5, borderRadius: 3, border: '1px solid rgba(255,255,255,0.34)' }} />
          {s.stale}
        </div>
      )}
    </div>
  );
}

// ── Dynamic Island ───────────────────────────────────────────
function LAIslandMinimal({ s }) {
  return (
    <div style={{ width: 37, height: 37, borderRadius: 19, background: '#000', display: 'flex',
      alignItems: 'center', justifyContent: 'center' }}>
      <LAArrowEast size={17} />
    </div>
  );
}

function LAIslandCompact({ s }) {
  const tone = s.compact.tone;
  const c = tone === 'stale' ? 'rgba(255,255,255,0.45)' : tone === 'dead' ? 'rgba(255,255,255,0.5)' : '#fff';
  const numeric = /^\d/.test(s.compact.text);
  return (
    <div style={{ height: 37, minWidth: 122, padding: '0 13px 0 11px', borderRadius: 19, background: '#000',
      display: 'inline-flex', alignItems: 'center', gap: 9, fontFamily: T.font }}>
      <span style={{ opacity: tone === 'dead' || tone === 'stale' ? 0.45 : 1, display: 'flex' }}><LAArrowEast size={16} /></span>
      <span style={{ fontFamily: numeric ? T.fontNum : T.font, fontSize: numeric ? 15 : 14.5, fontWeight: numeric ? 600 : 500,
        color: c, fontVariantNumeric: 'tabular-nums', letterSpacing: numeric ? -0.2 : -0.1, whiteSpace: 'nowrap' }}>{s.compact.text}</span>
    </div>
  );
}

function LAIslandExpanded({ s, width = 372 }) {
  const cd = s.headline.kind === 'countdown';
  return (
    <div style={{ width, borderRadius: 44, padding: '14px 20px 18px', boxSizing: 'border-box', background: '#000',
      fontFamily: T.font, color: '#fff', display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <HexLogo size={26} />
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
          {cd
            ? <><span style={{ fontSize: 12.5, color: 'rgba(255,255,255,0.55)', letterSpacing: -0.1 }}>{s.headline.prefix}</span>
                <LASecond second={s.second} size={12.5} /></>
            : <><span style={{ fontSize: 14.5, fontWeight: 500, letterSpacing: -0.25, lineHeight: 1.2 }}>{s.headline.text}</span>
                <LASecond second={s.second} size={12} /></>}
        </div>
        {cd
          ? <span style={{ fontFamily: T.fontNum, fontSize: 22, fontWeight: 600, fontVariantNumeric: 'tabular-nums',
              letterSpacing: -0.4, lineHeight: 1, flexShrink: 0, whiteSpace: 'nowrap' }}>{s.headline.value}<span style={{ fontFamily: T.font, fontSize: 14, fontWeight: 500, color: 'rgba(255,255,255,0.62)', marginLeft: 4 }}>{s.headline.unit}</span></span>
          : <LAChip label={s.chip} tone={s.tone} pulse={s.pulse} />}
      </div>
      {s.track && <LARail p={s.track.p} leg={s.track.leg} dim={!!s.stale} />}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, minHeight: 20 }}>
        {cd && <LAChip label={s.chip} tone={s.tone} pulse={s.pulse} />}
        {s.stale && <span style={{ fontSize: 11.5, color: 'rgba(255,255,255,0.42)' }}>{s.stale}</span>}
        {!cd && !s.stale && !s.track && <span style={{ fontSize: 11.5, color: 'rgba(255,255,255,0.34)' }}>Tap to open MyRoboTaxi</span>}
      </div>
    </div>
  );
}

// ── Frames ───────────────────────────────────────────────────
// Island states sit under a real bezel top edge so proportions read true.
function LAIslandFrame({ children, w = 372, label }) {
  return (
    <div style={{ width: w + 24, borderRadius: 40, padding: '0 12px 14px', background: 'linear-gradient(180deg,#232326,#131315)',
      boxShadow: '0 18px 40px rgba(0,0,0,0.5), inset 0 0 0 1px rgba(255,255,255,0.05)', paddingTop: 12 }}>
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
          <div style={{ fontSize: 15, color: 'rgba(255,255,255,0.72)' }}>Friday, July 31</div>
          <div style={{ fontSize: 84, fontWeight: 200, lineHeight: 1.05, letterSpacing: -3, color: '#fff' }}>4:06</div>
        </div>
      )}
      {children}
    </div>
  );
}

// Caption under an artboard specimen.
function LANote({ children, w = 350 }) {
  return <div style={{ width: w, fontFamily: T.font, fontSize: 11.5, lineHeight: 1.5, color: T.textMuted, textWrap: 'pretty' }}>{children}</div>;
}

function LAStack({ children, gap = 16, align = 'center' }) {
  return <div style={{ display: 'flex', flexDirection: 'column', gap, alignItems: align, justifyContent: 'center', height: '100%', padding: 22, boxSizing: 'border-box' }}>{children}</div>;
}

Object.assign(window, { LAArrowEast, LA_GROUND, LARail, LAChip, LAHeadline, LASecond, LALockCard, LAIslandMinimal, LAIslandCompact, LAIslandExpanded, LAIslandFrame, LAWallpaper, LANote, LAStack });
