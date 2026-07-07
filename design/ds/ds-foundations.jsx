// MyRoboTaxi · iOS Design System — Foundations sections.
// Brand · Color · Type · Spacing · Iconography · Surfaces · Motion.

const { useState: fS } = React;

// ── Brand ────────────────────────────────────────────────────
function BrandSection() {
  return (
    <Section id="brand" num="01" title="Brand"
      intro="A precise, premium robotaxi companion. Gold is the single accent against near-black — it marks anything live, owned, or actionable, and nothing else.">
      <Grid min={260}>
        <Card pad={0}>
          <Bay h={180} bg="dark" style={{ gap: 0 }}>
            <HexLogo size={84} glow />
          </Bay>
          <div style={{ padding: 18 }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: T.text, marginBottom: 4 }}>Brand mark</div>
            <div style={{ fontSize: 12.5, color: T.textSec, lineHeight: 1.5, marginBottom: 10 }}>A heading arrow — the vehicle in motion. Flat two-tone gold facet on a matte near-black tile, no glow. Min clear space = 0.5× height.</div>
            <Spec k="Tile radius" v="22.5% of size" />
            <Spec k="Facet" v="goldLight → goldDark" gold />
          </div>
        </Card>
        <Card pad={0}>
          <Bay h={180} bg="dark"><Wordmark size={30} /></Bay>
          <div style={{ padding: 18 }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: T.text, marginBottom: 4 }}>Wordmark</div>
            <div style={{ fontSize: 12.5, color: T.textSec, lineHeight: 1.5, marginBottom: 10 }}>All-caps “MYROBOTAXI” in Roboto Medium, single color, lightly tracked. No per-syllable color or weight changes — the mark carries the gold.</div>
            <Spec k="Family" v="Roboto" />
            <Spec k="Weight" v="500 · +0.04em" />
          </div>
        </Card>
        <Card>
          <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase', color: T.gold, marginBottom: 14 }}>Gold discipline</div>
          <Rule ok>Live ETA, active tab, route line, vehicle marker, primary CTA.</Rule>
          <Rule ok>One gold focal point per surface — let it lead the eye.</Rule>
          <Rule>Don’t use gold for body text, borders, or decoration.</Rule>
          <Rule>Don’t introduce a second accent hue — status colors only.</Rule>
        </Card>
      </Grid>
    </Section>
  );
}

// ── Color ────────────────────────────────────────────────────
function Swatch({ t }) {
  const [copied, setCopied] = fS(false);
  const copy = () => { navigator.clipboard?.writeText(t.hex); setCopied(true); setTimeout(() => setCopied(false), 900); };
  return (
    <div onClick={copy} style={{
      display: 'flex', alignItems: 'center', gap: 13, padding: '11px 13px', cursor: 'pointer',
      background: T.surface, borderRadius: 12, border: `0.5px solid ${T.border}`,
    }}>
      <div style={{ width: 40, height: 40, borderRadius: 9, background: t.hex, border: '0.5px solid rgba(255,255,255,0.12)', flexShrink: 0, boxShadow: t.hex === '#C9A84C' ? `0 0 14px ${T.goldGlow3}` : 'none' }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ fontSize: 13, color: T.text, fontWeight: 600 }}>{t.name}</span>
          <span style={{ fontFamily: DS_MONO, fontSize: 11, color: copied ? T.driving : T.textMuted }}>{copied ? 'copied' : t.hex}</span>
        </div>
        <div style={{ fontFamily: DS_MONO, fontSize: 11, color: T.gold, marginTop: 3, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{t.swift}</div>
        <div style={{ fontSize: 11, color: T.textSec, marginTop: 5, lineHeight: 1.4 }}>{t.usage}</div>
      </div>
    </div>
  );
}

function ColorSection() {
  const groups = [
    ['Brand', COLOR_TOKENS.brand], ['Surfaces', COLOR_TOKENS.surface],
    ['Text', COLOR_TOKENS.text], ['Status', COLOR_TOKENS.status],
  ];
  return (
    <Section id="color" num="02" title="Color"
      intro="A near-black, slightly-warm dark palette with a single gold accent and four functional status hues. Ship as a Dark-only Asset Catalog colorset. Tap any swatch to copy its hex.">
      {groups.map(([label, list]) => (
        <Sub key={label} title={label}>
          <Grid min={300}>{list.map((t) => <Swatch key={t.name} t={t} />)}</Grid>
        </Sub>
      ))}
      <Sub title="Contrast & accessibility" hint="WCAG on #0A0A0A">
        <Card>
          <Spec k="text on bg" v="≈ 19:1 · AAA" mono={false} gold />
          <Spec k="text.sec on bg" v="≈ 8.5:1 · AAA" mono={false} />
          <Spec k="gold on bg" v="≈ 8.1:1 · AAA (large + body)" mono={false} gold />
          <Spec k="text.muted on bg" v="≈ 4.6:1 · AA (labels ≥ 12pt only)" mono={false} />
          <div style={{ fontSize: 12, color: T.textSec, marginTop: 12, lineHeight: 1.55, paddingTop: 12, borderTop: `0.5px solid ${T.border}` }}>
            Never place <Mono>text.muted</Mono> on <Mono>surface</Mono> below 12pt. On <Mono gold>gold</Mono> fills, foreground is always <Mono>#1a1408</Mono> (near-black), never white.
          </div>
        </Card>
      </Sub>
    </Section>
  );
}

// ── Typography ───────────────────────────────────────────────
function TypeSection() {
  return (
    <Section id="type" num="03" title="Typography"
      intro="One family — the system font, SF Pro — so Dynamic Type and accessibility scaling work for free. Hierarchy lives in weight and size, not literal points. Every live numeric value uses monospaced digits to stop layout jitter.">
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {TYPE_TOKENS.map((t) => (
          <Card key={t.role} pad={0}>
            <div style={{ display: 'flex', alignItems: 'stretch', flexWrap: 'wrap' }}>
              <div style={{ flex: '1 1 240px', minWidth: 0, padding: '20px 22px', display: 'flex', alignItems: 'center', borderRight: `0.5px solid ${T.border}`, background: '#0d0d0f' }}>
                <span style={{
                  fontFamily: t.num ? T.fontNum : T.font,
                  fontSize: t.role === 'Screen Title' ? 30 : t.role === 'Hero Number' ? 40 : t.role === 'Section Title' ? 21 : t.role === 'Body' ? 16 : 13,
                  fontWeight: parseInt(t.px.split('/')[1]) || 400,
                  color: t.role === 'Hero Number' ? T.gold : T.text,
                  letterSpacing: t.role === 'Label' || t.role === 'Tab / Micro' ? 1.2 : -0.4,
                  textTransform: t.role === 'Label' || t.role === 'Tab / Micro' ? 'uppercase' : 'none',
                  fontVariantNumeric: t.num ? 'tabular-nums' : 'normal',
                }}>{t.sample}</span>
              </div>
              <div style={{ flex: '2 1 320px', padding: '18px 22px' }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 8 }}>
                  <span style={{ fontSize: 14, fontWeight: 600, color: T.text }}>{t.role}</span>
                  <span style={{ fontFamily: DS_MONO, fontSize: 11, color: T.textMuted }}>{t.px} · {t.track}</span>
                </div>
                <div style={{ fontFamily: DS_MONO, fontSize: 11.5, color: T.gold, marginBottom: 8 }}>{t.ios}</div>
                <div style={{ fontSize: 12.5, color: T.textSec, lineHeight: 1.5 }}>{t.notes}</div>
              </div>
            </div>
          </Card>
        ))}
      </div>
    </Section>
  );
}

// ── Spacing & radius ─────────────────────────────────────────
function SpacingSection() {
  const radii = RADIUS_LADDER;
  return (
    <Section id="spacing" num="04" title="Spacing & Radius"
      intro="A 24pt page gutter, 12pt rhythm between cards, and a small radius ladder. Liquid Glass mode rounds a few corners further; everything else is shared.">
      <Grid min={300}>
        <Card>
          <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase', color: T.gold, marginBottom: 10 }}>Layout constants</div>
          {SPACING_TOKENS.map((s) => (
            <div key={s.name} style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12, padding: '8px 0', borderTop: `0.5px solid ${T.border}` }}>
              <div style={{ minWidth: 0 }}>
                <div style={{ fontSize: 13, color: T.text, fontWeight: 500 }}>{s.name}</div>
                <div style={{ fontFamily: DS_MONO, fontSize: 10.5, color: T.textMuted, marginTop: 3 }}>{s.code}</div>
              </div>
              <span style={{ fontFamily: T.fontNum, fontSize: 17, fontWeight: 500, color: T.gold, fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>{s.val}</span>
            </div>
          ))}
        </Card>
        <Card>
          <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase', color: T.gold, marginBottom: 18 }}>Radius ladder</div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            {radii.map((x) => (
              <div key={x.label} style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
                <div style={{ width: 56, height: 56, flexShrink: 0, borderTopLeftRadius: x.r, background: 'rgba(255,255,255,0.04)', borderTop: `2px solid ${T.gold}`, borderLeft: `2px solid ${T.gold}` }} />
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 13.5, color: T.text, fontWeight: 500 }}>{x.label}</div>
                  <div style={{ fontFamily: DS_MONO, fontSize: 11, color: T.textMuted, marginTop: 2 }}>cornerRadius: {x.r}</div>
                </div>
                <span style={{ fontFamily: T.fontNum, fontSize: 15, color: T.gold, fontWeight: 500 }}>{x.r}pt</span>
              </div>
            ))}
          </div>
        </Card>
      </Grid>
    </Section>
  );
}

// ── Iconography ──────────────────────────────────────────────
function IconSection() {
  return (
    <Section id="icons" num="05" title="Iconography"
      intro="SF Symbols throughout, rendered at the system Regular weight. The prototype’s inline SVGs approximate these 1:1 — on device, use the named symbol. Custom vectors survive only for the hex logo and the vehicle marker.">
      <Grid min={150} gap={10}>
        {ICON_TOKENS.map((i) => (
          <div key={i.sym} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 14px', background: T.surface, borderRadius: 12, border: `0.5px solid ${T.border}` }}>
            <div style={{ width: 38, height: 38, borderRadius: 9, background: 'rgba(255,255,255,0.04)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
              <SFIcon name={i.sym} size={20} color={T.text} fill={i.sym.includes('.fill')} />
            </div>
            <div style={{ minWidth: 0 }}>
              <div style={{ fontFamily: DS_MONO, fontSize: 11, color: T.gold, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{i.sym}</div>
              <div style={{ fontSize: 11, color: T.textSec, marginTop: 3 }}>{i.use}</div>
            </div>
          </div>
        ))}
      </Grid>
    </Section>
  );
}

// ── Surfaces / elevation (Flat vs Liquid Glass) ──────────────
function SurfaceDemo({ liquid }) {
  // Render a representative card + button + chip in the chosen mode.
  return (
    <DesignCtx.Provider value={liquid ? 'liquid' : 'flat'}>
      <SurfaceDemoInner liquid={liquid} />
    </DesignCtx.Provider>
  );
}
function SurfaceDemoInner({ liquid }) {
  const S = useSurfaces();
  return (
    <div style={{ width: 260, display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ borderRadius: S.cardRadius, padding: 16, ...S.card }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
          <span style={{ fontSize: 15, fontWeight: 600, color: T.text }}>Cybercab</span>
          <StatusBadge status="driving" />
        </div>
        <TripProgressBar progress={0.46} origin="Home" dest="Pescadero" compact />
        <div style={{ display: 'flex', gap: 8, marginTop: 14 }}>
          <div style={{ padding: '6px 12px', borderRadius: 99, fontSize: 12, fontWeight: 600, ...S.chip(true) }}>Now</div>
          <div style={{ padding: '6px 12px', borderRadius: 99, fontSize: 12, fontWeight: 600, ...S.chip(false) }}>Schedule</div>
        </div>
      </div>
      <Button variant="gold" size="sm">Confirm pickup</Button>
    </div>
  );
}

function SurfaceSection() {
  return (
    <Section id="surfaces" num="06" title="Surfaces & Elevation"
      intro="Two interchangeable looks share one palette. Flat is solid #1A1A1A on #0A0A0A for maximum legibility and old-OS support. Liquid Glass (iOS 26) swaps fills for translucent material with a specular rim. Pick one app-wide via a single context value.">
      <Grid min={300}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <Bay h={300} bg="map" label="useSurfaces() === 'flat'"><SurfaceDemo liquid={false} /></Bay>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <Bay h={300} bg="map" label="useSurfaces() === 'liquid'"><SurfaceDemo liquid={true} /></Bay>
        </div>
      </Grid>
      <Sub title="Shadow & rim recipe" hint="Liquid Glass">
        <Grid min={260}>
          <Card>
            <Spec k="Blur" v="34px saturate(190%)" />
            <Spec k="Tint" v="rgba(48,48,56,0.52)" />
            <Spec k="Border" v="0.5px rgba(255,255,255,.22)" />
            <Spec k="Top rim" v="inset 0 1px rgba(255,255,255,.55)" />
            <Spec k="Drop" v="0 14px 38px rgba(0,0,0,.42)" />
          </Card>
          <Card>
            <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: 1, textTransform: 'uppercase', color: T.gold, marginBottom: 10 }}>iOS mapping</div>
            <Rule ok><Mono>.background(.ultraThinMaterial)</Mono> for glass surfaces on iOS 26.</Rule>
            <Rule ok>Flat fallback → <Mono>Color.mrtSurface</Mono> for &lt; iOS 26.</Rule>
            <Rule>Don’t stack two glass layers — readability collapses.</Rule>
          </Card>
        </Grid>
      </Sub>
    </Section>
  );
}

// ── Motion ───────────────────────────────────────────────────
function MotionSection() {
  return (
    <Section id="motion" num="07" title="Motion"
      intro="Motion is calm and physical — sheets settle with a spring, the Dynamic Island morphs, and only live elements loop. Honor Reduce Motion: traces and pulses fall back to static states.">
      <Grid min={300}>
        {MOTION_TOKENS.map((m) => (
          <Card key={m.name}>
            <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 8 }}>
              <span style={{ fontSize: 14, fontWeight: 600, color: T.text }}>{m.name}</span>
              <span style={{ fontFamily: T.fontNum, fontSize: 13, color: T.gold, fontWeight: 500 }}>{m.dur}</span>
            </div>
            <div style={{ fontFamily: DS_MONO, fontSize: 11, color: T.textMuted, marginBottom: 8 }}>{m.curve}</div>
            <div style={{ fontFamily: DS_MONO, fontSize: 11, color: T.gold, marginBottom: 10, lineHeight: 1.45 }}>{m.ios}</div>
            <div style={{ fontSize: 12.5, color: T.textSec, lineHeight: 1.5 }}>{m.use}</div>
          </Card>
        ))}
      </Grid>
    </Section>
  );
}

Object.assign(window, { BrandSection, ColorSection, TypeSection, SpacingSection, IconSection, SurfaceSection, MotionSection });
