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

// NOTE (mirror): the canonical file continues with window.SFIcon — inline SVG
// approximations of SF Symbols used only by the web prototype. Omitted here
// because iOS uses real SF Symbols via Image(systemName:) with the exact
// names listed in the Handoff §4; the SVG bodies carry no design truth for
// the native app. The window.T block above is verbatim.
