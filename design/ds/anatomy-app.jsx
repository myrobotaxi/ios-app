// MyRoboTaxi · Anatomy canvas — assembly.
// Pannable design canvas of exploded screen + component breakdowns.

function AnatomyApp() {
  return (
    <DesignCtx.Provider value="flat">
      <MRTStyles />
      <DesignCanvas>
        <DCSection id="overview" title="MyRoboTaxi · Screen Anatomy" subtitle="Labeled, exploded breakdowns for the iOS build — pair with the Design System spec sheet">
          <DCArtboard id="intro" label="Read me" width={520} height={420}>
            <Board w={520} h={420}>
              <div style={{ position: 'absolute', inset: 0, padding: 34, display: 'flex', flexDirection: 'column' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 20 }}>
                  <HexLogo size={38} glow /><Wordmark size={19} />
                </div>
                <div style={{ fontSize: 22, fontWeight: 600, color: T.text, letterSpacing: -0.5, lineHeight: 1.15, marginBottom: 14 }}>
                  Every numbered callout names a part, its token, and its spec.
                </div>
                <div style={{ fontSize: 13.5, color: T.textSec, lineHeight: 1.6, marginBottom: 'auto' }}>
                  Screens render at true 402×874. Drag artboards to reorder; open any in fullscreen
                  (←/→/Esc). Build each part as a SwiftUI view using the named token.
                </div>
                <div style={{ display: 'flex', gap: 10, marginTop: 20 }}>
                  <a href="Design System.html" style={ctaStyle(true)}>Design System spec →</a>
                  <a href="prototype.html" style={ctaStyle(false)}>Prototype</a>
                </div>
              </div>
            </Board>
          </DCArtboard>
        </DCSection>

        <DCSection id="screens" title="Screen anatomy" subtitle="Owner + shared flows, exploded">
          <DCArtboard id="signin" label="Sign In" width={1120} height={940}><BoardSignIn /></DCArtboard>
          <DCArtboard id="empty" label="Empty State" width={1120} height={940}><BoardEmpty /></DCArtboard>
          <DCArtboard id="addtesla" label="Add Your Tesla" width={1120} height={940}><BoardAddTesla /></DCArtboard>
          <DCArtboard id="invite" label="Enter Invite Code" width={1120} height={940}><BoardInvite /></DCArtboard>
          <DCArtboard id="tutorial" label="Tutorial · Story cards" width={1120} height={940}><BoardTutorial /></DCArtboard>
          <DCArtboard id="driving" label="Live Map · Driving" width={1120} height={940}><BoardDrivingHome /></DCArtboard>
          <DCArtboard id="parked" label="Live Map · Parked" width={1120} height={940}><BoardParkedHome /></DCArtboard>
          <DCArtboard id="drives" label="Drives" width={1120} height={940}><BoardDrives /></DCArtboard>
          <DCArtboard id="shared" label="Shared Viewer · Idle" width={1120} height={1000}><BoardSharedIdle /></DCArtboard>
          <DCArtboard id="booking" label="Booking · Sending" width={1120} height={1040}><BoardBooking /></DCArtboard>
          <DCArtboard id="tracking" label="Tracking" width={1120} height={1000}><BoardTracking /></DCArtboard>
          <DCArtboard id="summary" label="Ride Summary" width={1120} height={1040}><BoardSummary /></DCArtboard>
          <DCArtboard id="incoming" label="Incoming Request" width={1120} height={980}><BoardIncoming /></DCArtboard>
        </DCSection>

        <DCSection id="components" title="Component anatomy" subtitle="Exploded, in isolation">
          <DCArtboard id="tripbar" label="TripProgressBar" width={840} height={520}><BoardTripBar /></DCArtboard>
          <DCArtboard id="di" label="Dynamic Island" width={900} height={560}><BoardDI /></DCArtboard>
          <DCArtboard id="nav" label="Tab Bar" width={840} height={460}><BoardNav /></DCArtboard>
          <DCArtboard id="button" label="Button" width={840} height={460}><BoardButton /></DCArtboard>
          <DCArtboard id="cards" label="Tiles & Rows" width={900} height={520}><BoardCards /></DCArtboard>
        </DCSection>

        <DCSection id="surfaces" title="System surfaces" subtitle="Widgets · Dynamic Island states · Live Activity">
          <DCArtboard id="surf-link" label="Surfaces canvas" width={520} height={360}>
            <Board w={520} h={360}>
              <div style={{ position: 'absolute', inset: 0, padding: 34, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
                <div style={{ fontSize: 11, letterSpacing: 1.4, textTransform: 'uppercase', color: T.gold, fontWeight: 700, marginBottom: 12 }}>WidgetKit · ActivityKit</div>
                <div style={{ fontSize: 21, fontWeight: 600, color: T.text, letterSpacing: -0.4, lineHeight: 1.2, marginBottom: 12 }}>
                  Home & Lock widgets, StandBy, the DI long-press menu, and all Live Activity states live on their own canvas.
                </div>
                <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.55, marginBottom: 22 }}>
                  Each is sized to its real WidgetFamily, with the same token map.
                </div>
                <a href="surfaces.html" style={ctaStyle(true)}>Open surfaces canvas →</a>
              </div>
            </Board>
          </DCArtboard>
        </DCSection>
      </DesignCanvas>
    </DesignCtx.Provider>
  );
}

function ctaStyle(primary) {
  return {
    display: 'inline-flex', alignItems: 'center', gap: 7, padding: '10px 16px', borderRadius: 10,
    textDecoration: 'none', fontFamily: T.font, fontSize: 13, fontWeight: 600, letterSpacing: -0.1,
    background: primary ? T.gold : 'rgba(255,255,255,0.06)', color: primary ? '#1a1408' : T.text,
    border: primary ? 'none' : `0.5px solid ${T.border}`,
  };
}

ReactDOM.createRoot(document.getElementById('root')).render(<AnatomyApp />);
