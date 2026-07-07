// MyRoboTaxi — design-mode system.
// Two looks, one palette: 'flat' (the original solid-surface design) and
// 'liquid' (iOS 26 "Liquid Glass" — translucent, specular-edged glass).
// Every chrome surface reads its style from useSurfaces(), so a single
// context value repaints the whole app between looks while preserving the
// exact gold-on-dark color scheme.

window.DesignCtx = React.createContext('flat');
window.useDesign = function () { return React.useContext(window.DesignCtx); };

// ── Liquid Glass primitives ───────────────────────────────────
// The signature look = heavy blur + saturation, a bright specular top rim,
// a thin light border, a diagonal sheen, and a soft drop. Gold stays the
// accent for active / live elements exactly as in flat mode.
const LG = {
  blur:       'blur(34px) saturate(190%) brightness(1.08)',
  blurSoft:   'blur(22px) saturate(180%) brightness(1.06)',
  border:     '0.5px solid rgba(255,255,255,0.22)',
  borderSoft: '0.5px solid rgba(255,255,255,0.15)',
  tint:       'rgba(48,48,56,0.52)',
  tintStrong: 'rgba(30,30,36,0.60)',
  tintBanner: 'rgba(38,38,46,0.42)',
  // bright top edge + faint inner outline + gentle inner floor glow
  rim:        'inset 0 1px 0 rgba(255,255,255,0.55), inset 0 0 0 0.5px rgba(255,255,255,0.06), inset 0 -18px 32px rgba(255,255,255,0.035)',
  rimSoft:    'inset 0 1px 0 rgba(255,255,255,0.40), inset 0 0 0 0.5px rgba(255,255,255,0.06)',
  sheen:      'linear-gradient(135deg, rgba(255,255,255,0.18) 0%, rgba(255,255,255,0.04) 24%, rgba(255,255,255,0) 48%)',
  drop:       '0 14px 38px rgba(0,0,0,0.42)',
  dropLg:     '0 26px 70px rgba(0,0,0,0.6)',
  // inner inset control (search fields, stat strips) sitting on glass
  innerFill:  'rgba(255,255,255,0.07)',
  innerBorder:'0.5px solid rgba(255,255,255,0.13)',
  innerRim:   'inset 0 1px 0 rgba(255,255,255,0.10)',
};

function makeSurfaces(liquid) {
  const T = window.T;

  const glass = (tint, extraShadow) => ({
    backgroundColor: tint,
    backgroundImage: LG.sheen,
    backdropFilter: LG.blur, WebkitBackdropFilter: LG.blur,
    border: LG.border,
    boxShadow: LG.rim + (extraShadow ? ', ' + extraShadow : ''),
  });

  return {
    liquid,

    // Generic content card (drive rows, surface boxes)
    cardRadius: liquid ? 18 : 14,
    card: liquid
      ? glass(LG.tint, LG.drop)
      : { backgroundColor: T.surface, border: `0.5px solid ${T.border}` },

    // Bottom sheet (home). Layout/position stay in the component.
    sheetRadius: liquid ? 30 : T.radiusSheet,
    sheet: liquid
      ? { backgroundColor: LG.tintStrong, backgroundImage: LG.sheen,
          backdropFilter: LG.blur, WebkitBackdropFilter: LG.blur,
          border: LG.border, borderBottom: 'none',
          boxShadow: LG.rim + ', 0 -24px 60px rgba(0,0,0,0.5)' }
      : { backgroundColor: 'rgba(17,17,17,0.94)',
          backdropFilter: 'blur(28px) saturate(180%)', WebkitBackdropFilter: 'blur(28px) saturate(180%)',
          borderTop: `0.5px solid ${T.border}`,
          boxShadow: '0 -20px 60px rgba(0,0,0,0.6)' },

    // Modal sheet (incoming request) + toast share the strong glass.
    modalRadius: liquid ? 32 : 28,
    modalSheet: liquid
      ? { backgroundColor: LG.tintStrong, backgroundImage: LG.sheen,
          backdropFilter: LG.blur, WebkitBackdropFilter: LG.blur,
          border: LG.border,
          boxShadow: LG.rim + ', 0 -30px 80px rgba(0,0,0,0.7)' }
      : { backgroundColor: 'rgba(20,20,22,0.96)',
          backdropFilter: 'blur(28px) saturate(180%)', WebkitBackdropFilter: 'blur(28px) saturate(180%)',
          border: `0.5px solid ${T.border}`,
          boxShadow: '0 -30px 80px rgba(0,0,0,0.7)' },

    // Bottom tab bar. In liquid it detaches into a floating capsule.
    navFloating: liquid,
    navRadius: liquid ? 30 : 0,
    navInset: liquid ? 10 : 0,
    nav: liquid
      ? { backgroundColor: LG.tintStrong, backgroundImage: LG.sheen,
          backdropFilter: LG.blur, WebkitBackdropFilter: LG.blur,
          border: LG.border,
          boxShadow: LG.rim + ', ' + LG.dropLg }
      : { backgroundColor: 'rgba(10,10,10,0.92)',
          backdropFilter: 'blur(24px) saturate(180%)', WebkitBackdropFilter: 'blur(24px) saturate(180%)',
          borderTop: `0.5px solid ${T.border}` },

    // Floating round map button.
    floatBtn: liquid
      ? { ...glass(LG.tint, LG.drop) }
      : { backgroundColor: 'rgba(17,17,17,0.85)',
          backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)',
          border: `0.5px solid ${T.border}`,
          boxShadow: '0 4px 16px rgba(0,0,0,0.4)' },

    // Top banners / pills overlaid on the map.
    bannerRadius: liquid ? 18 : 14,
    banner: liquid
      ? { backgroundColor: LG.tintBanner, backgroundImage: LG.sheen,
          backdropFilter: LG.blurSoft, WebkitBackdropFilter: LG.blurSoft,
          border: LG.borderSoft,
          boxShadow: LG.rimSoft + ', ' + LG.drop }
      : { backgroundColor: 'rgba(17,17,17,0.85)',
          backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)',
          border: `0.5px solid ${T.border}` },

    // Inset control surface (search inputs, stat strips, nearby chips) that
    // lives INSIDE a sheet/card. Flat = solid elevated; liquid = clear glass.
    innerRadius: liquid ? 14 : 12,
    inner: liquid
      ? { backgroundColor: LG.innerFill, border: LG.innerBorder, boxShadow: LG.innerRim }
      : { backgroundColor: T.elevated, border: `0.5px solid ${T.border}` },

    // Sort / filter chip.
    chip(active) {
      if (active) {
        return liquid
          ? { backgroundColor: 'rgba(201,168,76,0.20)', border: `0.5px solid ${T.gold}99`,
              color: T.gold, boxShadow: `inset 0 1px 0 rgba(255,255,255,0.18), 0 2px 10px ${T.goldGlow3}` }
          : { backgroundColor: `${T.gold}1A`, border: `0.5px solid ${T.gold}`, color: T.gold };
      }
      return liquid
        ? { backgroundColor: 'rgba(255,255,255,0.06)', border: '0.5px solid rgba(255,255,255,0.14)',
            color: T.textSec, boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.10)' }
        : { backgroundColor: 'transparent', border: `0.5px solid ${T.border}`, color: T.textSec };
    },

    // Buttons. Liquid pill-rounds them and adds gloss; flat is unchanged.
    buttonRadius(h) { return liquid ? h / 2 : T.radiusInput; },
    button(variant) {
      if (!liquid) return null; // flat: let Button use its own variant table
      switch (variant) {
        case 'gold':
          return { backgroundColor: T.gold,
            backgroundImage: 'linear-gradient(180deg, rgba(255,255,255,0.34) 0%, rgba(255,255,255,0) 46%)',
            color: '#1a1408', border: 'none',
            boxShadow: `inset 0 1px 0 rgba(255,255,255,0.55), 0 8px 22px rgba(201,168,76,0.34)` };
        case 'outline':
          return { backgroundColor: 'rgba(201,168,76,0.12)',
            backgroundImage: LG.sheen,
            color: T.gold, border: `0.5px solid ${T.gold}88`,
            backdropFilter: LG.blurSoft, WebkitBackdropFilter: LG.blurSoft,
            boxShadow: LG.rimSoft };
        case 'outline-draw':
          return { backgroundColor: 'rgba(22,20,14,0.86)',
            color: T.gold, border: '0.5px solid rgba(201,168,76,0.30)' };
        case 'outline-static':
          return { backgroundColor: 'rgba(22,20,14,0.86)',
            color: T.gold, border: `0.5px solid ${T.gold}55` };
        case 'outline-muted':
          return { backgroundColor: 'rgba(255,255,255,0.08)',
            backgroundImage: LG.sheen,
            color: T.text, border: LG.border,
            backdropFilter: LG.blurSoft, WebkitBackdropFilter: LG.blurSoft,
            boxShadow: LG.rimSoft };
        default:
          return null; // ghost etc.
      }
    },

    // Toggle track.
    toggleTrack(on) {
      if (on) {
        return liquid
          ? { backgroundColor: T.gold, backgroundImage: 'linear-gradient(180deg, rgba(255,255,255,0.30), rgba(255,255,255,0) 50%)',
              boxShadow: `inset 0 1px 0 rgba(255,255,255,0.4), 0 2px 8px ${T.goldGlow3}` }
          : { backgroundColor: T.gold };
      }
      return liquid
        ? { backgroundColor: 'rgba(255,255,255,0.14)', boxShadow: 'inset 0 1px 1px rgba(0,0,0,0.3)' }
        : { backgroundColor: T.elevated };
    },
  };
}

window.useSurfaces = function () { return makeSurfaces(window.useDesign() === 'liquid'); };
window.makeSurfaces = makeSurfaces;

// ── Segmented Flat / Liquid toggle (used in the prototype chrome) ──
window.DesignToggle = function DesignToggle({ value, onChange }) {
  const T = window.T;
  const opts = [['flat', 'Flat'], ['liquid', 'Liquid Glass']];
  return (
    <div style={{
      display: 'flex', padding: 3, gap: 2, borderRadius: 12,
      background: 'rgba(255,255,255,0.05)', border: '0.5px solid rgba(255,255,255,0.10)',
    }}>
      {opts.map(([k, label]) => {
        const on = value === k;
        return (
          <button key={k} onClick={() => onChange(k)} style={{
            flex: 1, padding: '7px 10px', borderRadius: 9, border: 'none', cursor: 'pointer',
            fontFamily: T.font, fontSize: 11.5, fontWeight: 600, letterSpacing: 0.1,
            color: on ? (k === 'liquid' ? '#1a1408' : T.text) : T.textSec,
            background: on
              ? (k === 'liquid'
                  ? 'linear-gradient(180deg, rgba(255,255,255,0.34), rgba(255,255,255,0) 50%), ' + T.gold
                  : 'rgba(255,255,255,0.14)')
              : 'transparent',
            boxShadow: on ? 'inset 0 1px 0 rgba(255,255,255,0.4), 0 1px 6px rgba(0,0,0,0.3)' : 'none',
            transition: 'background .2s, color .2s',
            whiteSpace: 'nowrap',
          }}>{label}</button>
        );
      })}
    </div>
  );
};
