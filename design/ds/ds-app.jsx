// MyRoboTaxi · iOS Design System — page assembly.

const TOC_ITEMS = [
  { id: 'brand',      label: 'Brand' },
  { id: 'color',      label: 'Color' },
  { id: 'type',       label: 'Typography' },
  { id: 'spacing',    label: 'Spacing & Radius' },
  { id: 'icons',      label: 'Iconography' },
  { id: 'surfaces',   label: 'Surfaces' },
  { id: 'motion',     label: 'Motion' },
  { id: 'components',  label: 'Components' },
  { id: 'screens',    label: 'Screens' },
  { id: 'handoff',    label: 'Handoff' },
];

function DesignSystemPage() {
  return (
    <DesignCtx.Provider value="flat">
      <MRTStyles />
      <div style={{
        minHeight: '100vh', background: T.bg, color: T.text, fontFamily: T.font,
        backgroundImage: 'radial-gradient(ellipse at 15% 0%, rgba(201,168,76,0.06), transparent 45%), radial-gradient(ellipse at 90% 8%, rgba(48,209,88,0.03), transparent 40%)',
      }}>
        <div style={{ maxWidth: 1120, margin: '0 auto', padding: '0 32px', display: 'flex', gap: 44, alignItems: 'flex-start' }}>
          <TOC items={TOC_ITEMS} />
          <main style={{ flex: 1, minWidth: 0, paddingBottom: 100 }}>
            <Hero />
            <BrandSection />
            <ColorSection />
            <TypeSection />
            <SpacingSection />
            <IconSection />
            <SurfaceSection />
            <MotionSection />
            <ComponentsSection />
            <ScreensSection />
            <HandoffSection />
            <footer style={{ paddingTop: 40, textAlign: 'center', color: T.textMuted, fontSize: 12, letterSpacing: 0.3 }}>
              MyRoboTaxi · iOS Design System · v1.0 — generated from the live prototype components.
            </footer>
          </main>
        </div>
      </div>
    </DesignCtx.Provider>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<DesignSystemPage />);
