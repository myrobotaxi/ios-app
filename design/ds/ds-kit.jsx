// MyRoboTaxi · iOS Design System — documentation kit.
// Layout + presentational primitives for the spec page. Reads window.T.

const { useState: kS, useEffect: kE, useRef: kR } = React;

const MONO = 'ui-monospace, "SF Mono", "SFMono-Regular", Menlo, monospace';

// Inline monospace token / code chip
function Mono({ children, gold, dim, style }) {
  return (
    <span style={{
      fontFamily: MONO, fontSize: 12, letterSpacing: -0.2,
      color: gold ? T.gold : dim ? T.textMuted : T.textSec,
      background: 'rgba(255,255,255,0.05)', border: `0.5px solid ${T.border}`,
      borderRadius: 6, padding: '1.5px 6px', whiteSpace: 'nowrap', ...style,
    }}>{children}</span>
  );
}

// Small uppercase tag pill
function Tag({ children, tone = 'gold' }) {
  const map = {
    gold:    { c: T.gold,     b: 'rgba(201,168,76,0.14)', bd: 'rgba(201,168,76,0.30)' },
    driving: { c: T.driving,  b: 'rgba(48,209,88,0.12)',  bd: 'rgba(48,209,88,0.28)' },
    neutral: { c: T.textSec,  b: 'rgba(255,255,255,0.05)',bd: T.border },
  };
  const m = map[tone] || map.gold;
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 5,
      fontSize: 10, fontWeight: 700, letterSpacing: 0.8, textTransform: 'uppercase',
      color: m.c, background: m.b, border: `0.5px solid ${m.bd}`,
      borderRadius: 99, padding: '3px 9px', fontFamily: T.font,
    }}>{children}</span>
  );
}

// ── Page hero ────────────────────────────────────────────────
function Hero() {
  return (
    <header style={{ padding: '76px 0 40px', borderBottom: `0.5px solid ${T.border}`, marginBottom: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 30 }}>
        <HexLogo size={52} glow />
        <div>
          <Wordmark size={26} />
          <div style={{ fontSize: 12.5, color: T.textMuted, letterSpacing: 0.3, marginTop: 6 }}>
            Robotaxi fleet companion · iOS
          </div>
        </div>
      </div>
      <h1 style={{
        fontSize: 52, fontWeight: 600, letterSpacing: -1.6, lineHeight: 1.04,
        color: T.text, margin: '0 0 18px', maxWidth: 760, textWrap: 'pretty',
      }}>
        The official <span style={{ color: T.gold }}>iOS design system</span> & screen anatomy
      </h1>
      <p style={{ fontSize: 17, lineHeight: 1.55, color: T.textSec, maxWidth: 600, margin: '0 0 28px', fontWeight: 400 }}>
        One source of truth for engineers building the native app — tokens mapped to SwiftUI,
        every component speced to the point, and a labeled breakdown of all screens.
      </p>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
        <Tag>SwiftUI</Tag><Tag>MapKit</Tag><Tag>WidgetKit</Tag><Tag>ActivityKit</Tag>
        <Tag tone="neutral">iPhone 14 Pro +</Tag><Tag tone="neutral">Dark only</Tag>
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, marginTop: 30 }}>
        <DocLink href="Anatomy.html" primary>Open anatomy canvas →</DocLink>
        <DocLink href="prototype.html">Interactive prototype</DocLink>
        <DocLink href="surfaces.html">Widgets & Live Activity</DocLink>
      </div>
    </header>
  );
}

function DocLink({ href, children, primary }) {
  return (
    <a href={href} style={{
      display: 'inline-flex', alignItems: 'center', gap: 7,
      padding: '10px 18px', borderRadius: 11, textDecoration: 'none',
      fontFamily: T.font, fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
      background: primary ? T.gold : 'rgba(255,255,255,0.05)',
      color: primary ? '#1a1408' : T.text,
      border: primary ? 'none' : `0.5px solid ${T.border}`,
      backgroundImage: primary ? 'linear-gradient(180deg, rgba(255,255,255,0.28), rgba(255,255,255,0) 50%)' : 'none',
    }}>{children}</a>
  );
}

// ── Sticky table of contents ─────────────────────────────────
function TOC({ items }) {
  const [active, setActive] = kS(items[0] && items[0].id);
  kE(() => {
    const obs = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) setActive(e.target.id); });
    }, { rootMargin: '-20% 0px -70% 0px' });
    items.forEach((i) => { const el = document.getElementById(i.id); if (el) obs.observe(el); });
    return () => obs.disconnect();
  }, []);
  return (
    <nav style={{ position: 'sticky', top: 40, alignSelf: 'flex-start', width: 196, flexShrink: 0, paddingTop: 76 }}>
      <div style={{ fontSize: 10, letterSpacing: 1.4, textTransform: 'uppercase', color: T.textMuted, fontWeight: 600, marginBottom: 14, paddingLeft: 13 }}>Contents</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
        {items.map((i, n) => {
          const on = active === i.id;
          return (
            <a key={i.id} href={`#${i.id}`} style={{
              display: 'flex', alignItems: 'center', gap: 9, padding: '7px 13px', borderRadius: 8,
              textDecoration: 'none', fontFamily: T.font, fontSize: 13, fontWeight: on ? 600 : 400,
              color: on ? T.gold : T.textSec,
              background: on ? 'rgba(201,168,76,0.10)' : 'transparent',
              transition: 'color .15s, background .15s',
            }}>
              <span style={{ fontFamily: MONO, fontSize: 10, opacity: on ? 0.9 : 0.4, color: on ? T.gold : T.textMuted, width: 14 }}>{String(n + 1).padStart(2, '0')}</span>
              {i.label}
            </a>
          );
        })}
      </div>
      <div style={{ marginTop: 22, paddingTop: 16, borderTop: `0.5px solid ${T.border}`, paddingLeft: 13, fontSize: 11, color: T.textMuted, lineHeight: 1.6 }}>
        <div style={{ marginBottom: 8 }}>v1.0 · {new Date().toLocaleDateString('en-US', { month: 'short', year: 'numeric' })}</div>
        <a href="Anatomy.html" style={{ color: T.gold, textDecoration: 'none' }}>Anatomy canvas →</a>
      </div>
    </nav>
  );
}

// ── Section + subsection ─────────────────────────────────────
function Section({ id, num, title, intro, children }) {
  return (
    <section id={id} style={{ padding: '64px 0', borderBottom: `0.5px solid ${T.border}`, scrollMarginTop: 24 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 14, marginBottom: intro ? 16 : 30 }}>
        <span style={{ fontFamily: MONO, fontSize: 13, color: T.gold, fontWeight: 500 }}>{num}</span>
        <h2 style={{ fontSize: 30, fontWeight: 600, letterSpacing: -0.8, color: T.text, margin: 0 }}>{title}</h2>
      </div>
      {intro && <p style={{ fontSize: 15.5, lineHeight: 1.6, color: T.textSec, maxWidth: 620, margin: '0 0 34px' }}>{intro}</p>}
      {children}
    </section>
  );
}

function Sub({ title, hint, children, style }) {
  return (
    <div style={{ marginTop: 38, ...style }}>
      {title && (
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 16, marginBottom: 16 }}>
          <h3 style={{ fontSize: 13, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase', color: T.gold, margin: 0 }}>{title}</h3>
          {hint && <span style={{ fontSize: 12, color: T.textMuted, letterSpacing: -0.1 }}>{hint}</span>}
        </div>
      )}
      {children}
    </div>
  );
}

// Generic surface card
function Card({ children, pad = 20, style }) {
  return (
    <div style={{
      background: T.surface, border: `0.5px solid ${T.border}`, borderRadius: 16,
      padding: pad, ...style,
    }}>{children}</div>
  );
}

// Key/value spec line
function Spec({ k, v, mono = true, gold }) {
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 14, padding: '7px 0' }}>
      <span style={{ fontSize: 12.5, color: T.textSec, fontWeight: 400, flexShrink: 0 }}>{k}</span>
      <span style={{
        fontFamily: mono ? MONO : T.font, fontSize: 12, textAlign: 'right',
        color: gold ? T.gold : T.text, fontWeight: 500, letterSpacing: -0.1,
      }}>{v}</span>
    </div>
  );
}

// A staging surface to show a live component on. `bg`: 'dark' | 'panel' | 'map'
function Bay({ children, bg = 'panel', label, h, pad = 28, style }) {
  const bgs = {
    dark:  '#070707',
    panel: 'linear-gradient(180deg, #141416, #0e0e10)',
    map:   '#1b1d21',
  };
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10, ...style }}>
      <div style={{
        position: 'relative', borderRadius: 16, overflow: 'hidden',
        border: `0.5px solid ${T.border}`, background: bgs[bg] || bgs.panel,
        minHeight: h, padding: pad,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        backgroundImage: bg === 'panel'
          ? 'radial-gradient(ellipse at 50% 0%, rgba(201,168,76,0.05), transparent 60%)'
          : undefined,
      }}>{children}</div>
      {label && <div style={{ fontSize: 11, color: T.textMuted, letterSpacing: 0.3, textAlign: 'center' }}>{label}</div>}
    </div>
  );
}

// ── Mini phone — renders a screen component scaled down ───────
// The screens are authored at 402×874 and positioned absolute inset:0.
function MiniPhone({ children, scale = 0.42, label, di, bezel = true }) {
  const W = 402, H = 874;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12 }}>
      <div style={{ width: W * scale, height: H * scale, position: 'relative', flexShrink: 0 }}>
        <div style={{
          position: 'absolute', top: 0, left: 0, width: W, height: H,
          transform: `scale(${scale})`, transformOrigin: 'top left',
          borderRadius: bezel ? 46 : 30, overflow: 'hidden',
          background: '#000',
          border: bezel ? '6px solid #1c1c1f' : `0.5px solid ${T.border}`,
          boxShadow: '0 24px 60px rgba(0,0,0,0.5)',
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
      {label && (
        <div style={{ textAlign: 'center', maxWidth: W * scale + 30 }}>
          {label}
        </div>
      )}
    </div>
  );
}

// Two-column responsive grid
function Grid({ children, min = 240, gap = 16, style }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: `repeat(auto-fill, minmax(${min}px, 1fr))`, gap, ...style }}>{children}</div>
  );
}

// Do / Don't callout
function Rule({ ok, children }) {
  const c = ok ? T.driving : '#FF6B6B';
  return (
    <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', padding: '10px 0' }}>
      <span style={{ flexShrink: 0, width: 18, height: 18, borderRadius: 9, background: `${c}1f`, display: 'flex', alignItems: 'center', justifyContent: 'center', marginTop: 1 }}>
        <SFIcon name={ok ? 'checkmark' : 'xmark'} size={11} color={c} weight={2.4} />
      </span>
      <span style={{ fontSize: 13, color: T.textSec, lineHeight: 1.5 }}>{children}</span>
    </div>
  );
}

Object.assign(window, { Mono, Tag, Hero, DocLink, TOC, Section, Sub, Card, Spec, Bay, MiniPhone, Grid, Rule, DS_MONO: MONO });
