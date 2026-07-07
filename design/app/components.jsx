// Shared MyRoboTaxi components — replicate web design system on iOS.
// All references T.* from window.T (tokens.js).

const { useState, useEffect, useRef, useMemo } = React;

// ─────────────────────────────────────────────────────────────
// Brand wordmark — lowercase "myrobotaxi", light grotesque, single color.
// ─────────────────────────────────────────────────────────────
function Wordmark({ size = 24, color, withLogo = false }) {
  return (
    <div style={{ display: 'inline-flex', alignItems: 'center', gap: size * 0.5, fontFamily: T.font }}>
      {withLogo && <HexLogo size={size * 1.25} />}
      <div style={{
        fontFamily: '"Roboto", ' + T.font,
        fontSize: size, fontWeight: 500, letterSpacing: size * 0.04,
        textTransform: 'uppercase',
        color: color || T.text, lineHeight: 1
      }}>
        myrobotaxi
      </div>
    </div>);

}

// Brand mark — flat two-tone gold facet arrow on a matte near-black tile.
// (Name kept as HexLogo so existing call sites keep working.)
function HexLogo({ size = 32, glow = false }) {
  const arrow = size * 0.56;
  return (
    <div style={{ position: 'relative', width: size, height: size, borderRadius: size * 0.225, flexShrink: 0, overflow: 'hidden',
      background: 'linear-gradient(155deg, #1b1407 0%, #0d0b06 55%, #090806 100%)',
      boxShadow: `0 ${size * 0.04}px ${size * 0.12}px rgba(0,0,0,0.5), inset 0 0 0 0.5px rgba(255,255,255,0.07)`,
      display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ position: 'absolute', inset: 0, background: 'radial-gradient(95% 80% at 32% 2%, rgba(201,168,76,0.16), rgba(201,168,76,0) 60%)' }} />
      {glow && <div style={{ position: 'absolute', width: size * 0.92, height: size * 0.92, borderRadius: '50%',
        background: 'radial-gradient(circle, rgba(201,168,76,0.28), rgba(201,168,76,0) 62%)' }} />}
      <svg width={arrow} height={arrow} viewBox="0 0 100 100" style={{ position: 'relative', display: 'block' }}>
        <g transform="rotate(-22 50 50)">
          <polygon points="50,12 50,64 18,85" fill="#E4D08A" />
          <polygon points="50,12 82,85 50,64" fill="#9C7E2C" />
        </g>
      </svg>
    </div>);

}

// Bare symbol — arrow only, no tile (for tight / inverted contexts).
function ArrowMark({ size = 32, glow = false }) {
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" style={{ display: 'block', flexShrink: 0,
      filter: glow ? `drop-shadow(0 0 ${size * 0.18}px ${T.goldGlow6})` : undefined }}>
      <g transform="rotate(-22 50 50)">
        <polygon points="50,12 50,64 18,85" fill="#E4D08A" />
        <polygon points="50,12 82,85 50,64" fill="#9C7E2C" />
      </g>
    </svg>);

}

// ─────────────────────────────────────────────────────────────
// StatusBadge — 2px dot + label, no background fill.
// ─────────────────────────────────────────────────────────────
const STATUS = {
  driving: { c: T.driving, label: 'Driving' },
  parked: { c: T.parked, label: 'Parked' },
  charging: { c: T.charging, label: 'Charging' },
  offline: { c: T.offline, label: 'Offline' }
};
function StatusBadge({ status, size = 12 }) {
  const s = STATUS[status] || STATUS.parked;
  return (
    <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontFamily: T.font }}>
      <span style={{ width: 6, height: 6, borderRadius: 3, background: s.c, boxShadow: `0 0 6px ${s.c}55` }} />
      <span style={{ fontSize: size, color: T.textSec, fontWeight: 500, letterSpacing: 0.2 }}>{s.label}</span>
    </div>);

}

// Pulsing live dot (for "Driving now" banners, viewers online, etc.)
function PulseDot({ color = T.driving, size = 8 }) {
  return (
    <span style={{ position: 'relative', display: 'inline-block', width: size, height: size }}>
      <span style={{ position: 'absolute', inset: 0, borderRadius: '50%', background: color, animation: 'mrt-pulse-ring 2s ease-out infinite' }} />
      <span style={{ position: 'absolute', inset: 0, borderRadius: '50%', background: color }} />
    </span>);

}

// ─────────────────────────────────────────────────────────────
// BatteryBar — 1px tall by default (web spec), with threshold color.
// ─────────────────────────────────────────────────────────────
function batteryColor(pct) {
  if (pct < 20) return T.batLow;
  if (pct < 50) return T.batMid;
  return T.batHigh;
}
function BatteryBar({ pct, height = 6, showLabel = false, charging = false, style }) {
  const c = charging ? T.charging : batteryColor(pct);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, fontFamily: T.fontNum, ...style }}>
      <div style={{ flex: 1, height, background: T.elevated, borderRadius: height, overflow: 'hidden' }}>
        <div style={{ width: `${Math.max(pct, 3)}%`, height: '100%', background: c, borderRadius: height, transition: 'width .4s ease-out' }} />
      </div>
      {showLabel &&
      <span style={{ fontSize: 12, color: T.textSec, fontVariantNumeric: 'tabular-nums', minWidth: 32, textAlign: 'right' }}>
          {Math.round(pct)}%
        </span>
      }
    </div>);

}

// ─────────────────────────────────────────────────────────────
// MiniBattery — small Tesla-style battery glyph filled relative to
// full. Used inline (e.g. as the label under a range stat).
// ─────────────────────────────────────────────────────────────
function MiniBattery({ pct, charging = false, width = 26, height = 9 }) {
  const c = charging ? T.charging : pct <= 10 ? T.batLow : pct <= 20 ? T.batMid : T.batHigh;
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 2 }}>
      <span style={{ position: 'relative', display: 'inline-block', width, height, borderRadius: 2.5, border: `1px solid ${T.elevated}`, padding: 1.3, boxSizing: 'border-box' }}>
        <span style={{ display: 'block', height: '100%', width: `${Math.max(8, pct)}%`, borderRadius: 1.5, background: c, boxShadow: `0 0 5px ${c}44` }} />
      </span>
      <span style={{ display: 'inline-block', width: 1.5, height: height * 0.4, borderRadius: 1, background: T.elevated }} />
    </span>);

}

// ─────────────────────────────────────────────────────────────
// TripProgressBar — the signature element. Robinhood-style glowing.
// ─────────────────────────────────────────────────────────────
function TripProgressBar({ progress = 0.42, stops = [], origin, dest, compact = false }) {
  const p = Math.max(0.05, Math.min(0.95, progress));
  return (
    <div style={{ width: '100%', fontFamily: T.font }}>
      <div style={{ position: 'relative', height: 14, marginBottom: compact ? 0 : 12 }}>
        {/* Track — a solid, rounded pill so it reads crisp, not brittle */}
        <div style={{ position: 'absolute', left: 0, right: 0, top: '50%', height: 6, marginTop: -3, background: T.elevated, borderRadius: 6 }} />
        {/* Travelled portion — solid gold fill with rounded caps */}
        <div style={{
          position: 'absolute', left: 0, top: '50%', height: 6, marginTop: -3, width: `${p * 100}%`,
          background: T.gold, borderRadius: 6,
          transition: 'width .8s cubic-bezier(.4,0,.2,1)'
        }} />
        {/* Current position — glowing gold orb, matching the map markers */}
        <span style={{
          position: 'absolute', left: `${p * 100}%`, top: '50%',
          width: 15, height: 15, marginLeft: -7.5, marginTop: -7.5,
          borderRadius: '50%', background: T.gold,
          border: `2px solid ${T.text}`,
          boxShadow: `0 0 0 1px rgba(0,0,0,0.4), 0 0 6px ${T.goldGlow6}, 0 0 14px ${T.goldGlow3}`,
          transition: 'left .8s cubic-bezier(.4,0,.2,1)'
        }} />
      </div>
      {!compact && (origin || dest) &&
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, color: T.textMuted, fontWeight: 400, letterSpacing: -0.1 }}>
          <span>{origin}</span>
          <span style={{ color: T.textSec }}>{dest}</span>
        </div>
      }
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Vertical stat divider for stat rows in the bottom sheet.
// ─────────────────────────────────────────────────────────────
function StatCol({ label, value, unit, accent = false, align = 'center' }) {
  return (
    <div style={{ flex: 1, textAlign: align }}>
      <div style={{
        fontFamily: T.fontNum, fontSize: 23, fontWeight: 300, lineHeight: 1,
        color: accent ? T.gold : T.text, fontVariantNumeric: 'tabular-nums',
        letterSpacing: -0.6
      }}>
        {value}{unit && <span style={{ fontSize: 12.5, color: T.textMuted, marginLeft: 2, fontWeight: 400 }}>{unit}</span>}
      </div>
      <div style={{ fontSize: 10, color: T.textMuted, fontWeight: 500, letterSpacing: 1, textTransform: 'uppercase', marginTop: 7 }}>
        {label}
      </div>
    </div>);

}
// Clean stat cluster — Apple spaces these with whitespace, never hard rules.
function StatRow({ children }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8 }}>
      {children}
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Label (UPPERCASE, wide-tracked section header)
// ─────────────────────────────────────────────────────────────
function Label({ children, color = T.textMuted, style }) {
  return (
    <div style={{
      fontFamily: T.font, fontSize: 10, fontWeight: 500,
      letterSpacing: 1.2, textTransform: 'uppercase',
      color, ...style
    }}>{children}</div>);

}

// ─────────────────────────────────────────────────────────────
// Button — gold filled or outline.
// ─────────────────────────────────────────────────────────────
function Button({ children, variant = 'gold', onClick, fullWidth = true, leading, icon, size = 'md', style, flat = false }) {
  const S = useSurfaces();
  const h = size === 'sm' ? 38 : size === 'lg' ? 52 : 46;
  const variants = {
    gold: { bg: T.gold, color: '#1a1408', border: 'none' },
    outline: { bg: 'transparent', color: T.gold, border: `1px solid ${T.gold}` },
    'outline-draw': { bg: 'rgba(201,168,76,0.06)', color: T.gold, border: '1px solid rgba(201,168,76,0.22)' },
    'outline-static': { bg: 'rgba(201,168,76,0.06)', color: T.gold, border: `1px solid ${T.gold}55` },
    'outline-muted': { bg: 'transparent', color: T.text, border: `1px solid ${T.border}` },
    ghost: { bg: 'transparent', color: T.textSec, border: 'none' }
  };
  const v = variants[variant] || variants.gold;
  const lg = flat ? null : S.button(variant);
  // Flat = elegant deep gold-brown (not the bright liquid yellow-gold)
  const flatStyle = !flat ? null :
    variant === 'gold' ? { backgroundColor: T.goldDeep, color: '#1c1505', border: 'none' } :
    variant === 'outline' ? { backgroundColor: 'transparent', color: T.goldDeepSoft, border: `1px solid ${T.goldDeep}` } :
    null;
  return (
    <button onClick={onClick} className={variant === 'outline-draw' ? 'mrt-draw-btn' : undefined} style={{
      width: fullWidth ? '100%' : 'auto', height: h,
      backgroundColor: v.bg, backgroundImage: 'none', color: v.color, border: v.border,
      borderRadius: flat ? T.radiusInput : S.buttonRadius(h),
      ...(lg || {}),
      ...(flatStyle || {}),
      fontFamily: T.font, fontSize: 15, fontWeight: variant === 'gold' || variant === 'outline-draw' || variant === 'outline-static' ? 600 : 500,
      letterSpacing: -0.1,
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 8,
      padding: '0 18px', cursor: 'pointer', WebkitTapHighlightColor: 'transparent',
      transition: 'background .15s, transform .08s',
      ...style
    }}
    onMouseDown={(e) => e.currentTarget.style.transform = 'scale(0.98)'}
    onMouseUp={(e) => e.currentTarget.style.transform = ''}
    onMouseLeave={(e) => e.currentTarget.style.transform = ''}>
      {leading}
      <span>{children}</span>
      {icon}
    </button>);

}

// ─────────────────────────────────────────────────────────────
// Toggle — gold when on.
// ─────────────────────────────────────────────────────────────
function Toggle({ value, onChange }) {
  const S = useSurfaces();
  return (
    <button onClick={() => onChange && onChange(!value)} style={{
      width: 51, height: 31, padding: 0, border: 'none',
      borderRadius: 16,
      position: 'relative', cursor: 'pointer',
      transition: 'background .2s',
      ...S.toggleTrack(value)
    }}>
      <span style={{
        position: 'absolute', top: 2, left: value ? 22 : 2,
        width: 27, height: 27, borderRadius: '50%',
        background: '#fff', transition: 'left .22s cubic-bezier(.3,.7,.4,1)',
        boxShadow: '0 2px 4px rgba(0,0,0,0.3)'
      }} />
    </button>);

}

// ─────────────────────────────────────────────────────────────
// Avatar — circle with initials or color.
// ─────────────────────────────────────────────────────────────
function Avatar({ name = '?', size = 36, online = false }) {
  const initials = name.split(' ').map((s) => s[0]).slice(0, 2).join('').toUpperCase();
  // Stable color from name hash
  const hue = name.split('').reduce((a, c) => a + c.charCodeAt(0), 0) % 360;
  return (
    <div style={{ position: 'relative', width: size, height: size, flexShrink: 0 }}>
      <div style={{
        width: size, height: size, borderRadius: '50%',
        background: `oklch(0.4 0.08 ${hue})`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontFamily: T.font, fontSize: size * 0.36, fontWeight: 500,
        color: T.text, letterSpacing: 0.3
      }}>{initials}</div>
      {online && <span style={{
        position: 'absolute', bottom: 0, right: 0, width: size * 0.3, height: size * 0.3,
        borderRadius: '50%', background: T.driving, border: `2px solid ${T.bg}`
      }} />}
    </div>);

}

// ─────────────────────────────────────────────────────────────
// MapView — dark stylized map. Streets, blocks, terrain, then route.
// Renders an SVG. The "viewport" is 402 wide; we generate consistent paths
// from a seeded prng so it looks like a real map but stays deterministic.
// ─────────────────────────────────────────────────────────────
function seedRand(seed) {let s = seed;return () => (s = (s * 9301 + 49297) % 233280) / 233280;}

function MapBackground({ width = 402, height = 600, seed = 42, parkPan = 0 }) {
  const M = useMemo(() => {
    const r = seedRand(seed);
    const jitter = (a) => (r() - 0.5) * a;

    // ── Coastline: water fills the lower-left, land is upper-right.
    // A gently wavy diagonal coast so the route hugs the shore.
    const coast = [];
    const cn = 7;
    for (let i = 0; i <= cn; i++) {
      const t = i / cn;
      const x = t * width;
      const y = height * (0.92 - t * 0.42) + Math.sin(t * 7 + 1) * 14;
      coast.push([x, +y.toFixed(1)]);
    }
    let water = `M 0 ${height} L 0 ${coast[0][1]}`;
    coast.forEach((p) => {water += ` L ${p[0]} ${p[1]}`;});
    water += ` L ${width} ${height} Z`;
    // Coast stroke (just the shoreline, for a subtle lighter edge)
    let coastLine = `M ${coast[0][0]} ${coast[0][1]}`;
    coast.forEach((p) => {coastLine += ` L ${p[0]} ${p[1]}`;});

    // ── Parks (on land, upper-right side)
    const parks = [
    { cx: width * 0.70, cy: height * 0.20, rx: 58, ry: 44, rot: -12 },
    { cx: width * 0.30, cy: height * 0.16, rx: 40, ry: 34, rot: 8 },
    { cx: width * 0.86, cy: height * 0.52, rx: 34, ry: 50, rot: 18 }];


    // ── Street grid (generated in rotated space, oversized so edges hide)
    const pad = 120;
    const avenues = [],streets = [],collectors = [];
    const aGap = 44,sGap = 52;
    let idx = 0;
    for (let x = -pad; x < width + pad; x += aGap) {
      const d = `M ${x + jitter(8)} ${-pad} L ${x + jitter(8)} ${height + pad}`;
      (idx % 3 === 0 ? collectors : avenues).push(d);
      idx++;
    }
    idx = 0;
    for (let y = -pad; y < height + pad; y += sGap) {
      const d = `M ${-pad} ${y + jitter(8)} L ${width + pad} ${y + jitter(8)}`;
      (idx % 3 === 1 ? collectors : streets).push(d);
      idx++;
    }
    // ── One sweeping arterial / freeway across the map (calm, low amplitude)
    let free = `M -20 ${height * 0.62}`;
    for (let x = 0; x <= width + 40; x += 70) {
      free += ` Q ${x + 35} ${height * 0.62 + Math.sin(x / 130) * 22} ${x + 70} ${height * 0.60 + Math.sin(x / 110) * 20}`;
    }

    return { water, coastLine, parks, avenues, streets, collectors, free };
  }, [seed, width, height]);

  const cx = width / 2,cy = height / 2;
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} style={{ position: 'absolute', inset: 0, background: '#1b1d21', transform: `translateY(${parkPan}px)`, transition: 'transform .8s ease-out' }}>
      <defs>
        <radialGradient id="mapVignette" cx="0.5" cy="0.5" r="0.78">
          <stop offset="0.55" stopColor="rgba(0,0,0,0)" />
          <stop offset="1" stopColor="rgba(0,0,0,0.45)" />
        </radialGradient>
      </defs>

      {/* Land base */}
      <rect width={width} height={height} fill="#1b1d21" />

      {/* Parks (under roads, so streets cross them like real maps) */}
      {M.parks.map((p, i) =>
      <ellipse key={i} cx={p.cx} cy={p.cy} rx={p.rx} ry={p.ry} fill="#18221a" transform={`rotate(${p.rot} ${p.cx} ${p.cy})`} />
      )}

      {/* Street grid (rotated for an organic, non-axis-aligned feel) */}
      <g transform={`rotate(-15 ${cx} ${cy})`}>
        {/* residential — thin */}
        {M.streets.map((d, i) => <path key={`s${i}`} d={d} stroke="#26282d" strokeWidth="1.4" fill="none" />)}
        {M.avenues.map((d, i) => <path key={`a${i}`} d={d} stroke="#26282d" strokeWidth="1.4" fill="none" />)}
        {/* collectors — casing + lighter fill */}
        {M.collectors.map((d, i) => <path key={`cc${i}`} d={d} stroke="#2e3138" strokeWidth="5" fill="none" strokeLinecap="round" />)}
        {M.collectors.map((d, i) => <path key={`cf${i}`} d={d} stroke="#3c4049" strokeWidth="2.6" fill="none" strokeLinecap="round" />)}
      </g>

      {/* Freeway — warm tan, calmer than the route so it doesn't compete */}
      <path d={M.free} stroke="#2a2519" strokeWidth="6.5" fill="none" strokeLinecap="round" />
      <path d={M.free} stroke="#4c4330" strokeWidth="3" fill="none" strokeLinecap="round" />

      {/* Ocean — drawn over roads to mask them at the shoreline */}
      <path d={M.water} fill="#0e1a26" />
      <path d={M.coastLine} stroke="#16273a" strokeWidth="2" fill="none" />

      {/* Labels — subtle, sell the 'real map' feel */}
      <text x={width * 0.72} y={height * 0.80} fontFamily={T.font} fontSize="11" fontWeight="500" fill="rgba(150,180,210,0.36)" letterSpacing="0.4" transform={`rotate(-26 ${width * 0.72} ${height * 0.80})`}>Pacific Ocean</text>
      <text x={width * 0.62} y={height * 0.22} fontFamily={T.font} fontSize="8.5" fontWeight="600" fill="rgba(150,200,150,0.4)" letterSpacing="0.6" textAnchor="middle">PESCADERO PARK</text>
      <text x={width * 0.20} y={height * 0.60} fontFamily={T.font} fontSize="8.5" fontWeight="500" fill="rgba(255,255,255,0.26)" letterSpacing="0.5" transform={`rotate(-12 ${width * 0.20} ${height * 0.60})`}>Cabrillo Hwy</text>

      <rect width={width} height={height} fill="url(#mapVignette)" />
    </svg>);

}

// Compass labels on map edges
function CompassLabels({ width = 402, height = 600 }) {
  const cs = { position: 'absolute', fontFamily: T.font, fontSize: 9, fontWeight: 500, color: 'rgba(255,255,255,0.25)', letterSpacing: 2 };
  return (
    <>
      <div style={{ ...cs, top: 14, left: '50%', transform: 'translateX(-50%)' }}>N</div>
      <div style={{ ...cs, bottom: 14, left: '50%', transform: 'translateX(-50%)' }}>S</div>
      <div style={{ ...cs, top: '50%', left: 14, transform: 'translateY(-50%)' }}>W</div>
      <div style={{ ...cs, top: '50%', right: 14, transform: 'translateY(-50%)' }}>E</div>
    </>);

}

// Vehicle marker — gold circle, heading arrow, pulse ring.
function VehicleMarker({ heading = 45, size = 22, label }) {
  return (
    <div style={{ position: 'relative', width: 0, height: 0 }}>
      {/* Pulse ring */}
      <div style={{
        position: 'absolute', left: -size, top: -size, width: size * 2, height: size * 2,
        borderRadius: '50%', background: T.gold, opacity: 0.25,
        animation: 'mrt-pulse-ring 2s ease-out infinite'
      }} />
      {/* Heading arrow */}
      <svg width="44" height="44" viewBox="-22 -22 44 44" style={{
        position: 'absolute', left: -22, top: -22,
        transform: `rotate(${heading}deg)`, transformOrigin: 'center'
      }}>
        <path d="M 0 -16 L 5 -8 L 0 -10 L -5 -8 Z" fill={T.gold} opacity="0.9" />
      </svg>
      {/* Core dot */}
      <div style={{
        position: 'absolute', left: -size / 2, top: -size / 2,
        width: size, height: size, borderRadius: '50%',
        background: T.gold,
        border: `2px solid ${T.text}`,
        boxShadow: `0 0 0 1px rgba(0,0,0,0.4), 0 0 14px ${T.gold}, 0 0 28px ${T.goldGlow6}`
      }} />
      {label &&
      <div style={{
        position: 'absolute', left: size, top: -size * 0.6,
        background: 'rgba(10,10,10,0.85)', backdropFilter: 'blur(8px)',
        padding: '4px 8px', borderRadius: 6,
        fontFamily: T.font, fontSize: 10, color: T.gold, fontWeight: 600,
        letterSpacing: 0.3, whiteSpace: 'nowrap',
        border: `0.5px solid ${T.border}`
      }}>{label}</div>
      }
    </div>);

}

// Route line — two-tone gold polyline, split at vehicle progress.
function RouteLine({ path, progress = 0.4, width = 4, glow = true }) {
  // path: array of [x,y] points in svg space
  const totalLen = useMemo(() => {
    let len = 0;
    for (let i = 1; i < path.length; i++) {
      const dx = path[i][0] - path[i - 1][0];
      const dy = path[i][1] - path[i - 1][1];
      len += Math.sqrt(dx * dx + dy * dy);
    }
    return len;
  }, [path]);
  const d = useMemo(() => path.map((p, i) => `${i ? 'L' : 'M'} ${p[0]} ${p[1]}`).join(' '), [path]);
  const dashFront = totalLen * progress;
  return (
    <>
      <path d={d} stroke={T.gold} strokeOpacity="0.3" strokeWidth={width} fill="none" strokeLinecap="round" strokeLinejoin="round" />
      <path d={d} stroke={T.gold} strokeOpacity="0.95" strokeWidth={width} fill="none" strokeLinecap="round" strokeLinejoin="round"
      strokeDasharray={`${dashFront} ${totalLen}`}
      style={{ filter: glow ? `drop-shadow(0 0 4px ${T.goldGlow6})` : undefined }} />
    </>);

}

// Endpoint markers (start/end dots)
function EndpointDot({ x, y, color = T.gold, size = 10 }) {
  return (
    <g>
      <circle cx={x} cy={y} r={size * 0.9} fill={color} opacity="0.3" />
      <circle cx={x} cy={y} r={size / 2} fill={color} stroke="#fff" strokeWidth="1.5" />
    </g>);

}

// ─────────────────────────────────────────────────────────────
// BottomSheet — peek/half snap. Drag-handle, soft glassy backdrop.
// On iOS we'd map this to .presentationDetents([.height(260), .medium]);
// since native API can match the heights, we deviate only for the custom
// peek <-> half feel.
// ─────────────────────────────────────────────────────────────
function BottomSheet({ peekH = 260, halfH, height = 'peek', onChange, children, navHeight = 64 }) {
  const S = useSurfaces();
  const sheetRef = useRef(null);
  const dragRef = useRef({ active: false, startY: 0, startH: 0, h: 0 });
  const [liveH, setLiveH] = useState(height === 'peek' ? peekH : halfH);
  const containerH = sheetRef.current?.parentElement?.offsetHeight || 850;
  const halfActual = halfH ?? Math.round(containerH * 0.5);

  useEffect(() => {setLiveH(height === 'peek' ? peekH : halfActual);}, [height, peekH, halfActual]);

  const onPointerDown = (e) => {
    dragRef.current = { active: true, startY: e.clientY, startH: liveH, h: liveH };
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const onPointerMove = (e) => {
    if (!dragRef.current.active) return;
    const dy = e.clientY - dragRef.current.startY;
    const newH = Math.max(peekH - 30, Math.min(halfActual + 30, dragRef.current.startH - dy));
    dragRef.current.h = newH;
    setLiveH(newH);
  };
  const onPointerUp = (e) => {
    if (!dragRef.current.active) return;
    dragRef.current.active = false;
    const mid = (peekH + halfActual) / 2;
    const snap = dragRef.current.h > mid ? 'half' : 'peek';
    onChange && onChange(snap);
    setLiveH(snap === 'peek' ? peekH : halfActual);
  };

  return (
    <div ref={sheetRef} style={{
      position: 'absolute', left: 0, right: 0, bottom: navHeight,
      height: liveH,
      borderTopLeftRadius: S.sheetRadius, borderTopRightRadius: S.sheetRadius,
      ...S.sheet,
      transition: dragRef.current.active ? 'none' : 'height .3s cubic-bezier(.4,0,.2,1)',
      overflow: 'hidden', display: 'flex', flexDirection: 'column',
      zIndex: 30
    }}>
      {/* Drag handle */}
      <div onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerUp}
      style={{ padding: '10px 0 6px', cursor: 'grab', touchAction: 'none', flexShrink: 0 }}>
        <div style={{ width: 36, height: 4, background: T.elevated, borderRadius: 4, margin: '0 auto' }} />
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '6px 24px 100px', WebkitOverflowScrolling: 'touch' }}>
        {children}
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// BottomNav — 4-tab native tab bar.
// ─────────────────────────────────────────────────────────────
const OWNER_TABS = [
{ key: 'home', label: 'Vehicle', icon: 'car', iconActive: 'car.fill' },
{ key: 'drives', label: 'Drives', icon: 'clock', iconActive: 'clock.fill' },
{ key: 'invites', label: 'Share', icon: 'person.2', iconActive: 'person.2.fill' },
{ key: 'settings', label: 'Settings', icon: 'gearshape', iconActive: 'gearshape.fill' }];

const SHARED_TABS = [
{ key: 'shared', label: 'Live Map', icon: 'map', iconActive: 'map.fill' },
{ key: 'rideHistory', label: 'Ride History', icon: 'clock', iconActive: 'clock.fill' },
{ key: 'sharedSettings', label: 'Settings', icon: 'gearshape', iconActive: 'gearshape.fill' }];

const NAV_TABS = OWNER_TABS;
function BottomNav({ current, onChange, height = 60, tabs = OWNER_TABS, hidden = false }) {
  return (
    <div style={{
      position: 'absolute', left: 14, right: 14, bottom: 26, height,
      borderRadius: 24,
      background: 'rgba(22,22,25,0.92)',
      backdropFilter: 'blur(24px) saturate(1.5)', WebkitBackdropFilter: 'blur(24px) saturate(1.5)',
      border: '0.5px solid rgba(255,255,255,0.09)',
      boxShadow: '0 12px 34px rgba(0,0,0,0.5), 0 1px 0 rgba(255,255,255,0.06) inset',
      display: 'flex', alignItems: 'center',
      opacity: hidden ? 0 : 1,
      transform: hidden ? 'translateY(120%)' : 'translateY(0)',
      pointerEvents: hidden ? 'none' : 'auto',
      transition: 'transform .34s cubic-bezier(.32,.72,0,1), opacity .26s ease',
      zIndex: 40
    }}>
      {tabs.map((t) => {
        const active = current === t.key;
        // Brand palette, no cheap gray: bright gold when active, muted warm gold when not.
        const color = active ? T.gold : 'rgba(196,172,108,0.62)';
        return (
          <button key={t.key} onClick={() => onChange(t.key)} style={{
            flex: 1, height: '100%', padding: 0, border: 'none', background: 'transparent',
            display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 4,
            cursor: 'pointer', WebkitTapHighlightColor: 'transparent', transition: 'color .15s'
          }}>
            <SFIcon name={active ? t.iconActive : t.icon} size={22} color={color} fill={active} />
            <span style={{ fontFamily: T.font, fontSize: 10, fontWeight: active ? 600 : 500, color, letterSpacing: 0.1 }}>{t.label}</span>
          </button>);

      })}
    </div>);

}

// ─────────────────────────────────────────────────────────────
// KeyValue row — dense settings/details rows.
// ─────────────────────────────────────────────────────────────
function KV({ label, value, gold = false }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', padding: '8px 0', fontFamily: T.font }}>
      <span style={{ fontSize: 13, color: T.textSec, fontWeight: 400 }}>{label}</span>
      <span style={{ fontSize: 14, color: gold ? T.gold : T.text, fontWeight: 500, fontVariantNumeric: 'tabular-nums' }}>{value}</span>
    </div>);

}

// Section divider
function Divider({ pad = 14 }) {
  return <div style={{ height: 1, background: T.border, margin: `${pad}px 0` }} />;
}

// ─────────────────────────────────────────────────────────────
// Animations + global styles
// ─────────────────────────────────────────────────────────────
const MRT_STYLES = `
  @keyframes mrt-glow-breathe {
    0%, 100% { transform: scale(1); opacity: 0.85; }
    50% { transform: scale(1.4); opacity: 1; }
  }
  @keyframes mrt-pulse-ring {
    0% { transform: scale(0.6); opacity: 0.8; }
    100% { transform: scale(2.2); opacity: 0; }
  }
  @keyframes mrt-fade-up {
    from { opacity: 0; transform: translateY(8px); }
    to { opacity: 1; transform: translateY(0); }
  }
  @keyframes mrt-shimmer {
    0% { background-position: -200px 0; }
    100% { background-position: 200px 0; }
  }
  .mrt-reveal { animation: mrt-fade-up .4s ease-out both; }

  /* Request CTA — bright highlight that travels around the border (same seamless
     trace as the search bar), on a subtly filled pill. */
  .mrt-draw-btn { position: relative; isolation: isolate; box-shadow: 0 0 16px rgba(201,168,76,0.14); }
  .mrt-draw-btn::before {
    content: ''; position: absolute; inset: 0; border-radius: inherit;
    padding: 1.5px; pointer-events: none; z-index: 2;
    background: conic-gradient(from var(--mrt-trace),
      rgba(201,168,76,0.30) 0deg,
      rgba(201,168,76,0.30) 70deg,
      #E7C975 120deg,
      #FFF3C8 150deg,
      #E7C975 180deg,
      rgba(201,168,76,0.30) 240deg,
      rgba(201,168,76,0.30) 360deg);
    -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
    -webkit-mask-composite: xor; mask-composite: exclude;
    animation: mrt-trace-spin 2.6s linear infinite;
  }
  .mrt-draw-btn::after {
    content: ''; position: absolute; inset: -1px; border-radius: inherit;
    padding: 2px; pointer-events: none; z-index: 1;
    background: conic-gradient(from var(--mrt-trace),
      transparent 0deg, transparent 120deg,
      rgba(255,243,200,0.5) 150deg,
      transparent 180deg, transparent 360deg);
    -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
    -webkit-mask-composite: xor; mask-composite: exclude;
    filter: blur(4px);
    animation: mrt-trace-spin 2.6s linear infinite;
  }
  @media (prefers-reduced-motion: reduce) {
    .mrt-draw-btn::before { animation: none; background: linear-gradient(135deg, #E7C975, #C9A84C); opacity: 0.85; }
    .mrt-draw-btn::after { display: none; }
  }

  /* Search bar — a bright highlight that actively travels AROUND the border.
     Seamless because the conic gradient's 0deg and 360deg stops match. */
  @property --mrt-trace { syntax: '<angle>'; initial-value: 0deg; inherits: false; }
  .mrt-search-glow { position: relative; isolation: isolate; box-shadow: 0 0 16px rgba(201,168,76,0.16); }
  .mrt-search-glow::before {
    content: ''; position: absolute; inset: 0; border-radius: inherit;
    padding: 2px; pointer-events: none; z-index: 2;
    background: conic-gradient(from var(--mrt-trace),
      rgba(201,168,76,0.28) 0deg,
      rgba(201,168,76,0.28) 70deg,
      #E7C975 120deg,
      #FFF3C8 150deg,
      #E7C975 180deg,
      rgba(201,168,76,0.28) 240deg,
      rgba(201,168,76,0.28) 360deg);
    -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
    -webkit-mask-composite: xor; mask-composite: exclude;
    animation: mrt-trace-spin 2.6s linear infinite;
  }
  /* Comet glow that rides along with the highlight */
  .mrt-search-glow::after {
    content: ''; position: absolute; inset: -1px; border-radius: inherit;
    padding: 2px; pointer-events: none; z-index: 1;
    background: conic-gradient(from var(--mrt-trace),
      transparent 0deg, transparent 120deg,
      rgba(255,243,200,0.55) 150deg,
      transparent 180deg, transparent 360deg);
    -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
    -webkit-mask-composite: xor; mask-composite: exclude;
    filter: blur(4px);
    animation: mrt-trace-spin 2.6s linear infinite;
  }
  @keyframes mrt-trace-spin { to { --mrt-trace: 360deg; } }
  @media (prefers-reduced-motion: reduce) {
    .mrt-search-glow::before { animation: none; background: linear-gradient(135deg, #E7C975, #C9A84C); opacity: 0.85; }
    .mrt-search-glow::after { display: none; }
  }

  /* Gold text pulse/glow for the request CTA */
  @keyframes mrt-gold-pulse {
    0%, 100% { color: #C9A84C; text-shadow: 0 0 0 rgba(240,210,122,0); }
    50%      { color: #F0D27A; text-shadow: 0 0 14px rgba(240,210,122,0.55); }
  }
  .mrt-gold-pulse { animation: mrt-gold-pulse 2.4s ease-in-out infinite; }
  @media (prefers-reduced-motion: reduce) {
    .mrt-gold-pulse { animation: none; color: #F0D27A; }
  }

  /* Glowing 'ride ready' status dot */
  @keyframes mrt-ready-dot {
    0%, 100% { box-shadow: 0 0 0 0 rgba(201,168,76,0.55); }
    70%      { box-shadow: 0 0 0 6px rgba(201,168,76,0); }
  }
  .mrt-ready-dot { animation: mrt-ready-dot 2s ease-out infinite; }
  @media (prefers-reduced-motion: reduce) {
    .mrt-ready-dot { animation: none; box-shadow: 0 0 8px rgba(201,168,76,0.6); }
  }

  /* Hidden scrollbars for in-sheet scroll regions */
  .mrt-noscroll { scrollbar-width: none; -ms-overflow-style: none; }
  .mrt-noscroll::-webkit-scrollbar { display: none; width: 0; height: 0; }

  /* Schedule card slide-up */
  @keyframes mrt-sched-up {
    from { transform: translateY(100%); opacity: 0.4; }
    to   { transform: translateY(0); opacity: 1; }
  }

  /* Greeting — premium glow ease-in reveal */
  @keyframes mrt-greet-in {
    0%   { opacity: 0; transform: translateY(8px); filter: blur(8px); letter-spacing: 0.6px; }
    55%  { opacity: 1; filter: blur(0); }
    100% { opacity: 1; transform: translateY(0); filter: blur(0); letter-spacing: -0.4px; }
  }
  .mrt-greet { animation: mrt-greet-in .85s cubic-bezier(.22,1,.36,1) both; }
  @keyframes mrt-greet-glow {
    0%   { text-shadow: 0 0 0 rgba(201,168,76,0); opacity: 0.55; }
    40%  { text-shadow: 0 0 24px rgba(240,210,122,0.9); opacity: 1; }
    100% { text-shadow: 0 0 13px rgba(201,168,76,0.45); opacity: 1; }
  }
  .mrt-greet-name { animation: mrt-greet-glow 1.4s ease-out .12s both; }
  @media (prefers-reduced-motion: reduce) {
    .mrt-greet { animation: none; }
    .mrt-greet-name { animation: none; text-shadow: 0 0 13px rgba(201,168,76,0.45); }
  }

  /* Rotating placeholder — soft slide-up + blur clear */
  @keyframes mrt-ph-rotate {
    0%   { opacity: 0; transform: translateY(0.5em); filter: blur(3px); }
    100% { opacity: 1; transform: translateY(0); filter: blur(0); }
  }
  .mrt-ph-rotate { animation: mrt-ph-rotate .5s cubic-bezier(.22,1,.36,1) both; }
  @media (prefers-reduced-motion: reduce) { .mrt-ph-rotate { animation: none; } }

  /* Gold range slider (vehicle controls) */
  input.mrt-range { -webkit-appearance: none; appearance: none; width: 100%; height: 6px; border-radius: 6px; outline: none; margin: 0; cursor: pointer; }
  input.mrt-range::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 22px; height: 22px; border-radius: 11px; background: #fff; border: none; box-shadow: 0 1px 5px rgba(0,0,0,0.45); cursor: pointer; }
  input.mrt-range::-moz-range-thumb { width: 22px; height: 22px; border-radius: 11px; background: #fff; border: none; box-shadow: 0 1px 5px rgba(0,0,0,0.45); cursor: pointer; }
`;
function MRTStyles() {return <style dangerouslySetInnerHTML={{ __html: MRT_STYLES }} />;}

Object.assign(window, {
  Wordmark, HexLogo, ArrowMark, StatusBadge, PulseDot,
  BatteryBar, batteryColor, MiniBattery,
  TripProgressBar, StatCol, StatRow,
  Label, Button, Toggle, Avatar,
  MapBackground, CompassLabels, VehicleMarker, RouteLine, EndpointDot, seedRand,
  BottomSheet, BottomNav, NAV_TABS, OWNER_TABS, SHARED_TABS,
  KV, Divider, MRTStyles, STATUS
});
