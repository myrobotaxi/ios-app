// MyRoboTaxi · iOS Design System — reference data.
// Pure data tables consumed by the documentation page. No rendering here.

// ── Color tokens (Web hex → SwiftUI). Asset Catalog: Dark appearance only.
// `hex` is pulled live from window.T (tokens.js) so the spec can never drift
// from the running app — edit a color once in tokens.js and it updates here.
const _T = window.T;
window.COLOR_TOKENS = {
  brand: [
    { name: 'gold',        hex: _T.gold,        swift: 'Color.mrtGold',       usage: 'Sacred accent — CTAs, active nav, vehicle marker, route, brand. Never decorative.' },
    { name: 'gold.light',  hex: _T.goldLight,   swift: 'Color.mrtGoldLight',  usage: 'Pressed / highlight. Brand-mark arrow top facet.' },
    { name: 'gold.dark',   hex: _T.goldDark,    swift: 'Color.mrtGoldDark',   usage: 'Brand-mark arrow bottom facet, deep shadow.' },
    { name: 'gold.deep',   hex: _T.goldDeep,    swift: 'Color.mrtGoldDeep',   usage: 'Deep antique gold-brown — pairing stepper (done/active), gold-brown flat buttons.' },
    { name: 'gold.deepSoft',hex: _T.goldDeepSoft,swift: 'Color.mrtGoldDeepSoft',usage: 'Softer gold-brown — stepper labels + active numerals.' },
  ],
  surface: [
    { name: 'bg',          hex: _T.bg,          swift: 'Color.mrtBg',         usage: 'App shell, every screen background.' },
    { name: 'bg.secondary',hex: _T.bgSecondary, swift: 'Color.mrtBgSecondary',usage: 'Sheet fill (flat mode), grouped backdrops.' },
    { name: 'surface',     hex: _T.surface,     swift: 'Color.mrtSurface',    usage: 'Cards, input fields. Flat-mode card fill.' },
    { name: 'surface.hov', hex: _T.surfaceHov,  swift: 'Color.mrtSurfaceHov', usage: 'Pressed/hover card state.' },
    { name: 'elevated',    hex: _T.elevated,    swift: 'Color.mrtElevated',   usage: 'Toggle track (off), progress track, inset chips.' },
    { name: 'border',      hex: _T.border,      swift: 'Color.mrtBorder',     usage: 'Hairline 0.5pt dividers + card strokes.' },
  ],
  text: [
    { name: 'text',        hex: _T.text,        swift: 'Color.mrtText',       usage: 'Headlines + body. Foreground default.' },
    { name: 'text.sec',    hex: _T.textSec,     swift: 'Color.mrtTextSec',    usage: 'Subtitles, descriptions, secondary body.' },
    { name: 'text.muted',  hex: _T.textMuted,   swift: 'Color.mrtTextMuted',  usage: 'Labels, timestamps, captions, offline.' },
  ],
  status: [
    { name: 'driving',     hex: _T.driving,     swift: 'Color.mrtDriving',    usage: 'En-route status dot, origin map marker, online viewer.' },
    { name: 'parked',      hex: _T.parked,      swift: 'Color.mrtParked',     usage: 'Parked status dot, "available" indicators.' },
    { name: 'charging',    hex: _T.charging,    swift: 'Color.mrtCharging',   usage: 'Charging status, seat-heater levels, charge port.' },
    { name: 'danger',      hex: _T.batLow,      swift: 'Color.mrtDanger',     usage: 'Low battery, cancel / decline destructive actions.' },
  ],
};

// ── Type scale → SwiftUI. System font (SF Pro) for Dynamic Type support.
window.TYPE_TOKENS = [
  { role: 'Screen Title',  sample: 'Drives',            px: '28 / 600',    ios: '.title.weight(.semibold)',     track: '-0.6pt', notes: 'Top-of-screen headings. Scales with Dynamic Type.' },
  { role: 'Hero Number',   sample: '51',                px: '28–40 / 300', ios: '.largeTitle.weight(.light)',   track: '-1pt',   notes: 'Live ETA / temp / battery. ALWAYS .monospacedDigit().', num: true },
  { role: 'Section Title', sample: 'Cybercab',          px: '18 / 600',    ios: '.headline',                    track: '-0.3pt', notes: 'Vehicle name, card headings, sheet hero.' },
  { role: 'Body',          sample: 'Arriving in 12 min',px: '14–15 / 400', ios: '.subheadline / .body',         track: '0',      notes: 'Default copy. SF Pro Text regular.' },
  { role: 'Label',         sample: 'TIRE PRESSURE',     px: '10–12 / 500', ios: '.caption.weight(.medium)',     track: '+1.2pt', notes: '.textCase(.uppercase) + .kerning(1.2).' },
  { role: 'Tab / Micro',   sample: 'Settings',          px: '10 / 500',    ios: '.caption2.weight(.medium)',    track: '+0.1pt', notes: 'Tab-bar labels, micro timestamps.' },
];

// ── Spacing, radius, layout constants. Radii + page gutter read from tokens.js.
window.SPACING_TOKENS = [
  { name: 'Page horizontal', val: `${_T.pagePad}pt`,     code: `.padding(.horizontal, ${_T.pagePad})` },
  { name: 'Card gap',        val: '12pt',                code: 'VStack(spacing: 12)' },
  { name: 'Section gap',     val: '18–32pt',             code: '.padding(.vertical, …)' },
  { name: 'Card radius',     val: `${_T.radiusCard}pt`,  code: `cornerRadius: ${_T.radiusCard} (14 flat)` },
  { name: 'Input / Button',  val: `${_T.radiusInput}pt`, code: `cornerRadius: ${_T.radiusInput}` },
  { name: 'Bottom sheet',    val: `${_T.radiusSheet}pt`, code: `.presentationCornerRadius(${_T.radiusSheet})` },
  { name: 'Liquid sheet',    val: '30pt',                code: 'cornerRadius: 30 (liquid)' },
  { name: 'Floating nav',    val: `${_T.radiusSheet}pt`, code: 'capsule, inset 14pt' },
];

// Radius ladder (also from tokens.js) — consumed by the foundations page.
window.RADIUS_LADDER = [
  { label: 'Button / Input', r: _T.radiusInput },
  { label: 'Card',           r: _T.radiusCard },
  { label: 'Sheet',          r: _T.radiusSheet },
  { label: 'Liquid sheet',   r: 30 },
];

// ── SF Symbols mapping. The custom SVGs in tokens.js approximate these 1:1.
window.ICON_TOKENS = [
  { sym: 'car.fill',         use: 'Vehicle tab, ride detail' },
  { sym: 'clock.fill',       use: 'Drives / Ride-history tab' },
  { sym: 'person.2.fill',    use: 'Share / viewers tab' },
  { sym: 'gearshape.fill',   use: 'Settings tab' },
  { sym: 'map.fill',         use: 'Live Map (shared) tab' },
  { sym: 'location.fill',    use: 'Recenter, live position' },
  { sym: 'bolt.fill',        use: 'Charging, charge port' },
  { sym: 'mappin',           use: 'Pickup pin, destination' },
  { sym: 'magnifyingglass',  use: 'Destination search' },
  { sym: 'paperplane.fill',  use: 'Request sent, sending beacon' },
  { sym: 'bag',              use: 'Arrival reminder — grab belongings' },
  { sym: 'calendar',         use: 'Scheduled rides' },
  { sym: 'checkmark',        use: 'Accepted, confirmed' },
  { sym: 'xmark',            use: 'Close, decline, cancel' },
  { sym: 'chevron.right',    use: 'Row disclosure' },
  { sym: 'chevron.left',     use: 'Back navigation' },
  { sym: 'lock.fill',        use: 'Vehicle lock state' },
  { sym: 'fan',              use: 'Climate control' },
  { sym: 'play.fill',        use: 'Media transport' },
  { sym: 'square.and.arrow.up', use: 'Share a drive' },
  { sym: 'snowflake',        use: 'Defrost / cooling' },
  { sym: 'person.fill',      use: 'Revoke-access dialog, recipient avatar fallback' },
  { sym: 'envelope.fill',    use: 'Invite email field, cancel-invite dialog' },
  { sym: 'chevron.down',     use: 'Vehicle switcher chip disclosure' },
  { sym: 'arrow.up.right',   use: 'Open Tesla app, external handoff' },
];

// ── Motion — named animations + iOS mapping.
window.MOTION_TOKENS = [
  { name: 'Sheet snap',     dur: '.42s', curve: 'cubic-bezier(.32,.72,0,1)', ios: '.spring(response:0.42, dampingFraction:0.86)', use: 'Bottom-sheet height + detent changes.' },
  { name: 'DI expand',      dur: '.35s', curve: 'cubic-bezier(.4,0,.2,1)',   ios: 'matchedGeometryEffect', use: 'Dynamic Island compact ↔ expanded.' },
  { name: 'Reveal',         dur: '.4s',  curve: 'ease-out',                  ios: '.transition(.opacity.combined(with:.move(.bottom)))', use: 'Content fade-up on appear (mrt-fade-up).' },
  { name: 'Pulse ring',     dur: '2s',   curve: 'ease-out infinite',         ios: 'TimelineView', use: 'Live vehicle marker, "ready" dot.' },
  { name: 'Border trace',   dur: '2.6s', curve: 'linear infinite',           ios: 'AngularGradient + rotation', use: 'Search bar + request CTA highlight.' },
  { name: 'Send fill',      dur: '10s',  curve: 'linear forwards',           ios: '.scaleX 0→1 (TimelineView)', use: 'Sending-request CTA — gold fill slides L→R over the 10s send window; tap fast-forwards.' },
  { name: 'Title shimmer',  dur: '2.6s', curve: 'linear infinite',           ios: 'masked LinearGradient sweep', use: 'Arrival “Arriving” headline — soft white sheen across the gold text.' },
  { name: 'Greeting glow',  dur: '.85s', curve: 'cubic-bezier(.22,1,.36,1)', ios: '.blur + .opacity transition', use: 'Time-of-day greeting reveal.' },
  { name: 'Confirm dialog', dur: '.28s', curve: 'cubic-bezier(.32,.72,0,1)', ios: '.spring + .opacity', use: 'Center alert dialogs (revoke, unlink, cancel, sign out) — backdrop fade + card rise (mrt-sched-up).' },
  { name: 'Toast',          dur: '.3s',  curve: 'cubic-bezier(.32,.72,0,1)', ios: '.move(.bottom)+.opacity', use: 'Success confirmations (access revoked, invite sent/resent). Auto-dismiss ~2.8s.' },
  { name: 'Story slide',    dur: '.45s', curve: 'cubic-bezier(.22,1,.36,1)', ios: 'TabView(.page) transition',  use: 'Tutorial story cards — directional slide-in of vignette + text (mrtStoryInL/R).' },
  { name: 'Pair bloom',     dur: '.9s',  curve: 'cubic-bezier(.4,0,.2,1)',   ios: 'radial scale + fade',        use: 'Celebratory paired / joined moment — gold radial bloom + expanding rings + check pop.' },
  { name: 'Key shimmer',    dur: '2.4s', curve: 'ease infinite',             ios: 'masked gradient sweep',      use: 'Virtual key card — diagonal light sweep across the matte-black card (mrtShimmer).' },
  { name: 'Vignette float', dur: '4s',   curve: 'ease-in-out infinite',      ios: 'autoreversing offset',       use: 'Tutorial hero mini-screens — gentle vertical bob.' },
  { name: 'Code shake',     dur: '.4s',  curve: 'ease',                      ios: 'keyframe offset',            use: 'Invalid invite code / empty email — horizontal shake (mrtShake / mrt-invite-shake).' },
];

// ── Handoff: where iOS diverges from the web prototype.
window.DEVIATIONS = [
  ['Bottom sheet → .presentationDetents([.height(260), .medium])', 'Native detents match web peek (260pt) + half (≈50vh). Keep custom drag only for the home-indicator peek snap.'],
  ['Inter → SF Pro (system)', 'System font is required for Dynamic Type + accessibility. Preserve hierarchy via the type scale, not literal point sizes.'],
  ['Mapbox GL → MapKit', 'Native MKMapView for vehicle annotation + route overlay. Accept minor fidelity loss on building extrusions.'],
  ['Inline SVG icons → SF Symbols', '1:1 swap (see Iconography). Keep custom vectors only for the brand mark + vehicle marker.'],
  ['Swipe vehicle switch → tap switcher chip', 'Top-center capsule (car icon + vehicle name + chevron) opens a picker menu listing each vehicle with plate + active check. Replaces the old page-dots; avoids conflict with the MKMapView pan gesture and is a full 44pt target.'],
  ['Tesla pairing → ASWebAuthenticationSession + Tesla Fleet OAuth', 'The in-app browser mock maps to ASWebAuthenticationSession against Tesla’s real OAuth + virtual-key (BLE) enrollment. The scopes-consent + key-card screens shown are ORIGINAL mocks, not Tesla’s UI — rebuild against the real Fleet API.'],
  ['"Sign in with Apple" → AuthenticationServices', 'Native ASAuthorizationAppleIDButton — the sole auth method for both owner and shared flows. No third-party providers.'],
  ['Custom share modal → UIActivityViewController', 'System share sheet. Universal Link is the canonical deep-link payload.'],
  ['Liquid Glass → .ultraThinMaterial / glassEffect', 'On iOS 26 use the native glass APIs; the Flat fallback maps to solid .mrtSurface for older OSes.'],
];

window.OPEN_QUESTIONS = [
  ['Live Activity cadence', 'Push every 60s steady, 15s in the final 5 min before arrival? Confirm background budget.'],
  ['Stale-state policy', 'When does staleDate flip? Proposal: 4 min without an update.'],
  ['Push token routing', 'ActivityKit push channel separate from APNs alerts — backend ownership TBD.'],
  ['Multi-vehicle Siri intent', 'Default vehicle disambiguation: most-recently-active, or user-pinned?'],
  ['Widget refresh budget', 'Map-snippet widgets need a freshness floor. Acceptable cadence?'],
  ['AOD marker pulse', 'StandBy dims brightness — pause pulse, or run at reduced intensity?'],
];
