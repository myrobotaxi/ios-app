// MyRoboTaxi design tokens — mirrors the web design system.
// All consumers read from window.T.
window.T = {
  // Backgrounds
  bg:          '#0A0A0A',
  bgSecondary: '#111111',
  surface:     '#1A1A1A',
  surfaceHov:  '#222222',
  elevated:    '#2A2A2A',

  // Text
  text:        '#FFFFFF',
  textSec:     '#A0A0A0',
  textMuted:   '#6B6B6B',

  // Brand
  gold:        '#C9A84C',
  goldLight:   '#D4C88A',
  goldDark:    '#A0862E',
  // Deep antique gold-brown — used for the flat onboarding buttons + stepper
  goldDeep:    '#8C6E2A',
  goldDeepSoft:'#B49A56',
  goldGlow6:   'rgba(201,168,76,0.6)',
  goldGlow3:   'rgba(201,168,76,0.3)',

  // Status
  driving:     '#30D158',
  parked:      '#3B82F6',
  charging:    '#FFD60A',
  offline:     '#6B6B6B',

  // Battery
  batHigh:     '#30D158',
  batMid:      '#FFD60A',
  batLow:      '#FF3B30',

  // Borders
  border:      '#1F1F1F',
  borderSub:   '#181818',

  // Layout
  pagePad:     24,
  radiusCard:  16,
  radiusInput: 12,
  radiusSheet: 24,

  // Type — SF Pro (system) maps Inter; we preserve hierarchy.
  font:        '-apple-system, "SF Pro Text", "SF Pro Display", system-ui, sans-serif',
  fontNum:     '-apple-system, "SF Pro Text", system-ui, sans-serif',
};

// SF Symbol approximations as inline SVG. Drawn as 1.5px outline glyphs so
// they match SF Symbols Regular weight at our usual 22px nav size.
window.SFIcon = function SFIcon({ name, size = 22, color = 'currentColor', fill = false, weight = 1.5 }) {
  const s = size;
  const props = { width: s, height: s, viewBox: '0 0 24 24', fill: 'none', stroke: color, strokeWidth: weight, strokeLinecap: 'round', strokeLinejoin: 'round' };
  const filledProps = { width: s, height: s, viewBox: '0 0 24 24', fill: color };
  switch (name) {
    case 'map.fill':
      return fill ? (
        <svg {...filledProps}><path fillRule="evenodd" clipRule="evenodd" d="M8.16 2.58a1.88 1.88 0 0 1 1.68 0l4.99 2.5c.11.05.23.05.34 0l3.87-1.94a1.88 1.88 0 0 1 2.71 1.68v12.48c0 .71-.4 1.36-1.04 1.68l-4.87 2.44a1.88 1.88 0 0 1-1.68 0l-4.99-2.5a.38.38 0 0 0-.34 0L4.96 21.3a1.88 1.88 0 0 1-2.71-1.68V7.14c0-.71.4-1.36 1.04-1.68l4.87-2.44a.4.4 0 0 1 0-.44zM9 6a.75.75 0 0 1 .75.75V15a.75.75 0 0 1-1.5 0V6.75A.75.75 0 0 1 9 6zm6.75 3a.75.75 0 0 0-1.5 0v8.25a.75.75 0 0 0 1.5 0V9z"/></svg>
      ) : (
        <svg {...props}><path d="M9 4L3 6v15l6-2 6 2 6-2V4l-6 2-6-2zM9 4v15M15 6v15"/></svg>
      );
    case 'clock':
      return <svg {...props}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/></svg>;
    case 'clock.fill':
      return <svg {...filledProps}><path fillRule="evenodd" clipRule="evenodd" d="M12 2.25c-5.385 0-9.75 4.365-9.75 9.75s4.365 9.75 9.75 9.75 9.75-4.365 9.75-9.75S17.385 2.25 12 2.25zM12.75 6a.75.75 0 0 0-1.5 0v6c0 .414.336.75.75.75h4.5a.75.75 0 0 0 0-1.5h-3.75V6z"/></svg>;
    case 'person.2':
      return <svg {...props}><circle cx="9" cy="8" r="3"/><circle cx="17" cy="9" r="2.5"/><path d="M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6M14.5 14c2.6 0 4.5 1.9 4.5 4.5"/></svg>;
    case 'person.2.fill':
      return <svg {...filledProps}><path d="M9.5 11.5a3.25 3.25 0 1 0 0-6.5 3.25 3.25 0 0 0 0 6.5zm0 1.5c-3.18 0-5.75 1.9-5.75 4.25 0 .8.6 1.25 1.5 1.25h8.5c.9 0 1.5-.45 1.5-1.25C15.25 14.9 12.68 13 9.5 13zm7.4-1.6a2.75 2.75 0 1 0 0-5.5 2.75 2.75 0 0 0 0 5.5zm0 1.4c-.5 0-.97.07-1.4.2 1.05.92 1.73 2.16 1.86 3.5.03.32.3.6.62.6h2.27c.83 0 1.5-.45 1.5-1.2 0-1.98-2.2-3.1-4.85-3.1z"/></svg>;
    case 'gearshape':
      return <svg {...props}><path d="M19.43 12.98c.04-.32.07-.64.07-.98s-.03-.66-.07-.98l2.11-1.65c.19-.15.24-.42.12-.64l-2-3.46c-.12-.22-.39-.3-.61-.22l-2.49 1c-.52-.4-1.08-.73-1.69-.98l-.38-2.65C16.56 2.18 16.36 2 16.12 2h-4c-.24 0-.44.18-.49.42l-.38 2.65c-.61.25-1.17.59-1.69.98l-2.49-1c-.23-.09-.49 0-.61.22l-2 3.46c-.13.22-.07.49.12.64l2.11 1.65c-.04.32-.07.65-.07.98s.03.66.07.98l-2.11 1.65c-.19.15-.24.42-.12.64l2 3.46c.12.22.39.3.61.22l2.49-1c.52.4 1.08.73 1.69.98l.38 2.65c.05.24.25.42.49.42h4c.24 0 .44-.18.49-.42l.38-2.65c.61-.25 1.17-.59 1.69-.98l2.49 1c.23.09.49 0 .61-.22l2-3.46c.12-.22.07-.49-.12-.64l-2.11-1.65zM12 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7z"/></svg>;
    case 'gearshape.fill':
      return <svg {...filledProps}><path fillRule="evenodd" clipRule="evenodd" d="M11.08 2.25c-.92 0-1.7.66-1.85 1.57l-.11.66c-.04.2-.18.4-.42.5a7.5 7.5 0 0 0-.99.57c-.21.15-.46.18-.66.1l-.62-.23a1.88 1.88 0 0 0-2.28.82l-.46.8a1.88 1.88 0 0 0 .43 2.38l.5.42c.17.14.25.38.23.63a7.6 7.6 0 0 0 0 1.14c.02.25-.06.49-.23.63l-.5.41a1.88 1.88 0 0 0-.43 2.39l.46.8a1.88 1.88 0 0 0 2.28.81l.62-.23c.2-.07.45-.04.66.1.31.22.64.41.99.58.24.1.38.29.42.5l.1.65c.16.91.94 1.57 1.86 1.57h.92c.92 0 1.7-.66 1.85-1.57l.11-.66c.04-.2.18-.4.42-.5.34-.16.67-.36.98-.57.21-.14.46-.17.66-.1l.62.23a1.88 1.88 0 0 0 2.28-.82l.46-.8a1.88 1.88 0 0 0-.43-2.38l-.5-.42a.74.74 0 0 1-.23-.63 7.6 7.6 0 0 0 0-1.14.74.74 0 0 1 .23-.63l.5-.41a1.88 1.88 0 0 0 .43-2.39l-.46-.8a1.88 1.88 0 0 0-2.28-.81l-.62.23c-.2.07-.45.04-.66-.1a7.5 7.5 0 0 0-.98-.58.74.74 0 0 1-.42-.5l-.11-.65a1.88 1.88 0 0 0-1.85-1.57h-.92zM12 15.75a3.75 3.75 0 1 0 0-7.5 3.75 3.75 0 0 0 0 7.5z"/></svg>;
    case 'bolt.fill':
      return <svg {...filledProps}><path d="M13 2L4 14h6l-1 8 9-12h-6l1-8z"/></svg>;
    case 'battery.100':
      return <svg width={size * 1.6} height={size * 0.6} viewBox="0 0 36 14" fill="none" stroke={color} strokeWidth="1.2">
        <rect x="0.6" y="0.6" width="30.8" height="12.8" rx="3"/>
        <rect x="32.5" y="4" width="2" height="6" rx="1" fill={color}/>
        <rect x="2.5" y="2.5" width="27" height="9" rx="1.5" fill={color}/>
      </svg>;
    case 'chevron.left':
      return <svg {...props}><path d="M15 6l-6 6 6 6"/></svg>;
    case 'chevron.right':
      return <svg {...props}><path d="M9 6l6 6-6 6"/></svg>;
    case 'chevron.down':
      return <svg {...props}><path d="M6 9l6 6 6-6"/></svg>;
    case 'arrow.up.right':
      return <svg {...props}><path d="M7 17L17 7M9 7h8v8"/></svg>;
    case 'square.and.arrow.up':
      return <svg {...props}><path d="M12 3v13M8 7l4-4 4 4M5 13v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6"/></svg>;
    case 'xmark':
      return <svg {...props}><path d="M6 6l12 12M18 6L6 18"/></svg>;
    case 'plus':
      return <svg {...props}><path d="M12 5v14M5 12h14"/></svg>;
    case 'location':
      return <svg {...props}><path d="M12 2L8 12l4-2 4 2-4-10z" strokeLinejoin="round"/></svg>;
    case 'location.fill':
      return <svg {...filledProps}><path d="M12 2L7 12l5-2.5L17 12 12 2z"/></svg>;
    case 'locate':
      return <svg {...props}><circle cx="12" cy="12" r="6.5"/><circle cx="12" cy="12" r="1.7" fill={color} stroke="none"/><path d="M12 2.2v3.1M12 18.7v3.1M2.2 12h3.1M18.7 12h3.1"/></svg>;
    case 'mappin.circle.fill':
      return <svg {...filledProps}><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3" fill="#0A0A0A"/></svg>;
    case 'speedometer':
      return <svg {...props}><path d="M5 18a8 8 0 1 1 14 0"/><path d="M12 14l3.5-5"/><circle cx="12" cy="14" r="1.2" fill={color}/></svg>;
    case 'thermometer':
      return <svg {...props}><path d="M10 14V4a2 2 0 1 1 4 0v10a4 4 0 1 1-4 0z"/><line x1="12" y1="9" x2="12" y2="14"/></svg>;
    case 'figure.wave':
      return <svg {...props}><circle cx="14" cy="4.5" r="1.6"/><path d="M14 7l-2 4 3 2-1 6M12 11l-3-1 1-3 4-1"/></svg>;
    case 'arrow.triangle.turn.up.right.diamond':
      return <svg {...props}><path d="M12 2l10 10-10 10L2 12 12 2z"/><path d="M9 14v-2a2 2 0 0 1 2-2h4M13 8l3 2-3 2"/></svg>;
    case 'apple.logo':
      return <svg width={size} height={size} viewBox="0 0 24 24" fill={color}><path d="M17.05 12.04c-.03-2.85 2.32-4.21 2.43-4.28-1.33-1.94-3.39-2.2-4.12-2.23-1.75-.18-3.42 1.03-4.31 1.03-.9 0-2.27-1.01-3.74-.98-1.92.03-3.7 1.12-4.69 2.83-2 3.47-.51 8.6 1.44 11.42.96 1.38 2.09 2.93 3.58 2.87 1.44-.06 1.98-.93 3.72-.93 1.74 0 2.23.93 3.74.9 1.55-.03 2.53-1.4 3.48-2.79 1.1-1.6 1.55-3.15 1.58-3.23-.03-.01-3.03-1.16-3.06-4.61M14.6 4.05c.79-.96 1.32-2.29 1.18-3.62-1.14.05-2.52.76-3.34 1.72-.73.85-1.37 2.22-1.2 3.52 1.27.1 2.57-.65 3.36-1.62"/></svg>;
    case 'g.logo':
      return <svg width={size} height={size} viewBox="0 0 24 24"><path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/><path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.99.66-2.25 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/><path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"/><path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/></svg>;
    case 'pencil':
      return <svg {...props}><path d="M3 21l3-1L20 6l-2-2L4 18l-1 3z"/></svg>;
    case 'bell':
      return <svg {...props}><path d="M6 8a6 6 0 1 1 12 0c0 7 3 6 3 9H3c0-3 3-2 3-9zM10 21a2 2 0 0 0 4 0"/></svg>;
    case 'house.fill':
      return <svg {...filledProps}><path d="M12 3L3 10.5V21h6v-6h6v6h6V10.5L12 3z"/></svg>;
    case 'briefcase.fill':
      return <svg {...filledProps}><path d="M9 4h6a2 2 0 0 1 2 2v1h3a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h3V6a2 2 0 0 1 2-2zm0 3h6V6H9v1z"/></svg>;
    case 'car':
      return <svg {...props}><path d="M5 11l1.4-4.2A2 2 0 0 1 8.3 5.5h7.4a2 2 0 0 1 1.9 1.3L19 11M5 11h14a1.5 1.5 0 0 1 1.5 1.5V16a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1v-3.5A1.5 1.5 0 0 1 5 11z"/><path d="M7 14.5h.01M17 14.5h.01"/></svg>;
    case 'car.fill':
      return <svg {...filledProps}><path d="M4 13.2c0-.97.52-1.82 1.3-2.28l1.34-3.5A2.5 2.5 0 0 1 8.98 6h6.04a2.5 2.5 0 0 1 2.34 1.42l1.34 3.5c.78.46 1.3 1.31 1.3 2.28v2.55c0 .53-.36.98-.85 1.11v1.09a1.4 1.4 0 0 1-2.8 0v-1h-8.7v1a1.4 1.4 0 0 1-2.8 0v-1.09A1.15 1.15 0 0 1 4 15.75V13.2zm3.7-2.2h8.6l-1.07-2.8a1 1 0 0 0-.93-.64H9.7a1 1 0 0 0-.93.64L7.7 11zM7.25 14.6a1.15 1.15 0 1 0 0-2.3 1.15 1.15 0 0 0 0 2.3zm9.5 0a1.15 1.15 0 1 0 0-2.3 1.15 1.15 0 0 0 0 2.3z"/></svg>;
    case 'snowflake':
      return <svg {...props}><path d="M12 2v20M4 6l16 12M20 6L4 18M12 2l-2.5 2.5M12 2l2.5 2.5M12 22l-2.5-2.5M12 22l2.5-2.5M4 6l.3 3.4M4 6l3.4-.3M20 18l-.3-3.4M20 18l-3.4.3M20 6l-3.4.3M20 6l.3 3.4M4 18l3.4.3M4 18l.3-3.4"/></svg>;
    case 'sun.max.fill':
      return <svg {...filledProps}><circle cx="12" cy="12" r="5"/><g stroke={color} strokeWidth="2" strokeLinecap="round"><path d="M12 1v3M12 20v3M1 12h3M20 12h3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/></g></svg>;
    case 'fan':
      return <svg {...props}><circle cx="12" cy="12" r="1.6"/><path d="M12 10.5c0-3 .5-6.5-1.5-7.5C8 2 6.5 6 9 9.5M13.5 12c3 0 6.5.5 7.5-1.5C22 8 18 6.5 14.5 9M12 13.5c0 3-.5 6.5 1.5 7.5C16 22 17.5 18 15 14.5M10.5 12c-3 0-6.5-.5-7.5 1.5C2 16 6 17.5 9.5 15"/></svg>;
    case 'lock.fill':
      return <svg {...filledProps}><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3" fill="none" stroke={color} strokeWidth="2"/></svg>;
    case 'lock.open.fill':
      return <svg {...filledProps}><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 7.5-2" fill="none" stroke={color} strokeWidth="2"/></svg>;
    case 'play.fill':
      return <svg {...filledProps}><path d="M7 4.5v15l12-7.5z"/></svg>;
    case 'pause.fill':
      return <svg {...filledProps}><rect x="6.5" y="5" width="3.6" height="14" rx="1"/><rect x="13.9" y="5" width="3.6" height="14" rx="1"/></svg>;
    case 'forward.fill':
      return <svg {...filledProps}><path d="M3 5.5v13l8-6.5zM12.5 5.5v13l8-6.5z"/></svg>;
    case 'backward.fill':
      return <svg {...filledProps}><path d="M21 5.5v13l-8-6.5zM11.5 5.5v13l-8-6.5z"/></svg>;
    case 'speaker.wave.2.fill':
      return <svg {...filledProps}><path d="M4 9v6h3.5L13 19V5L7.5 9zM16 8.5a4 4 0 0 1 0 7M18.5 6a7 7 0 0 1 0 12" fill="none" stroke={color} strokeWidth="1.8" strokeLinecap="round"/><path d="M4 9v6h3.5L13 19V5L7.5 9z"/></svg>;
    case 'gauge':
      return <svg {...props}><path d="M4 18a8 8 0 1 1 16 0"/><path d="M12 18l4-5"/><circle cx="12" cy="18" r="1.3" fill={color}/></svg>;
    case 'wind':
      return <svg {...props}><path d="M3 8h11a3 3 0 1 0-3-3M3 16h14a3 3 0 1 1-3 3M3 12h7"/></svg>;
    case 'figure.run':
      return <svg {...props}><circle cx="14" cy="4.5" r="1.7"/><path d="M13 8l-3.5 3 2 2.5-1.5 5M11 11l-4-1.5M14 13l3 1.5 1.5 4"/></svg>;
    case 'checkmark':
      return <svg {...props}><path d="M5 12.5l4.5 4.5L19 6.5"/></svg>;
    case 'envelope.fill':
      return <svg {...filledProps}><path d="M3.5 6.5A1.5 1.5 0 0 1 5 5h14a1.5 1.5 0 0 1 1.5 1.5v.4l-8.5 5-8.5-5v-.4z"/><path d="M20.5 8.2l-8.13 4.78a.75.75 0 0 1-.74 0L3.5 8.2V17.5A1.5 1.5 0 0 0 5 19h14a1.5 1.5 0 0 0 1.5-1.5V8.2z"/></svg>;
    case 'face.smiling':
      return <svg {...props}><circle cx="12" cy="12" r="9"/><circle cx="8.8" cy="10" r="1.1" fill={color} stroke="none"/><circle cx="15.2" cy="10" r="1.1" fill={color} stroke="none"/><path d="M7.8 13.5a4.6 4.6 0 0 0 8.4 0z" fill={color} stroke="none"/></svg>;
    case 'bag.fill':
      return <svg {...filledProps}><path fillRule="evenodd" clipRule="evenodd" d="M8.5 7V6a3.5 3.5 0 1 1 7 0v1h2.2c.8 0 1.47.6 1.56 1.4l1.1 9.5A2 2 0 0 1 19.37 20H4.63a2 2 0 0 1-1.99-2.1l1.1-9.5A1.57 1.57 0 0 1 5.3 7H8.5zM10 7h4V6a2 2 0 1 0-4 0v1z"/></svg>;
    case 'bag':
      return <svg {...props}><path d="M6 8h12l.8 11a1.5 1.5 0 0 1-1.5 1.6H6.7A1.5 1.5 0 0 1 5.2 19L6 8z"/><path d="M9 8V6.5a3 3 0 0 1 6 0V8"/></svg>;
    case 'mappin':
      return <svg {...props}><path d="M12 21s7-6.3 7-11a7 7 0 1 0-14 0c0 4.7 7 11 7 11z"/><circle cx="12" cy="10" r="2.5"/></svg>;
    case 'person.fill':
      return <svg {...filledProps}><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.4 3.6-7 8-7s8 2.6 8 7v1H4v-1z"/></svg>;
    case 'person.2.crop':
      return <svg {...props}><circle cx="9" cy="8" r="3"/><circle cx="17" cy="9" r="2.3"/><path d="M3.5 19.5c0-3 2.5-5.5 5.5-5.5s5.5 2.5 5.5 5.5M15 14.2c2.4.1 4.5 1.9 4.5 4.5"/></svg>;
    case 'calendar':
      return <svg {...props}><rect x="3.5" y="5" width="17" height="16" rx="2.5"/><path d="M3.5 9.5h17M8 3v4M16 3v4"/></svg>;
    case 'magnifyingglass':
      return <svg {...props}><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.8-3.8"/></svg>;
    case 'paperplane.fill':
      return <svg {...filledProps}><path d="M21 3L3 10.5l6.5 2.5L12 21l9-18z"/></svg>;
    default:
      return <svg {...props}><circle cx="12" cy="12" r="8"/></svg>;
  }
};
