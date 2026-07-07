// Shared-viewer (guest) flow screens — Ride History + Settings.
// The guest can only request rides + watch the live map; these two
// screens round out their bottom-nav (Live Map · Ride History · Settings).

const { useState: ssS, useMemo: ssM, useEffect: ssE } = React;

// Rides Sam personally requested from shared vehicles (all free).
const REQUESTED_RIDES = [
{ id: 'r1', day: 'Today', date: 'Jun 15', from: 'Home', to: 'Ferry Building', driver: 'Alex', rel: 'Roommate', vehicle: 'Cybercab', start: '9:12 AM', miles: 3.4, mins: 14 },
{ id: 'r2', day: 'Yesterday', date: 'Jun 14', from: 'Marina Blvd', to: 'SFO · Terminal 2', driver: 'Mom', rel: 'Family', vehicle: 'Model Y', start: '6:40 AM', miles: 18.2, mins: 28, for: { name: 'Maya Chen', phone: '(415) 555-0142' } },
{ id: 'r3', day: 'Yesterday', date: 'Jun 14', from: 'SFO · Terminal 2', to: 'Home', driver: 'Jordan', rel: 'Friend', vehicle: 'Model 3', start: '7:55 PM', miles: 17.9, mins: 31 },
{ id: 'r4', day: 'Jun 11', date: 'Jun 11', from: 'Home', to: 'Dolores Park', driver: 'Alex', rel: 'Roommate', vehicle: 'Cybercab', start: '2:05 PM', miles: 2.1, mins: 11 },
{ id: 'r5', day: 'Jun 9', date: 'Jun 9', from: 'Work', to: 'Tartine Manufactory', driver: 'Jordan', rel: 'Friend', vehicle: 'Model 3', start: '12:30 PM', miles: 4.6, mins: 19, for: { name: 'Dad', phone: '(415) 555-0193' } }];


// Rides Sam has scheduled for later. status: confirmed = driver accepted; pending = awaiting.
const SCHEDULED_RIDES = [
{ id: 's1', day: 'Tomorrow', date: 'Jun 17', time: '6:30 AM', from: 'Home', to: 'SFO · Terminal 2', driver: 'Mom', rel: 'Family', vehicle: 'Model Y', miles: 18.4, status: 'confirmed' },
{ id: 's2', day: 'Thu', date: 'Jun 18', time: '9:00 AM', from: 'Home', to: 'Caltrain · 4th & King', driver: 'Jordan', rel: 'Friend', vehicle: 'Model 3', miles: 5.2, status: 'pending', for: { name: 'Maya Chen', phone: '(415) 555-0142' } },
{ id: 's3', day: 'Sat', date: 'Jun 20', time: '7:15 PM', from: 'Mission · Tartine', to: 'Home', driver: 'Alex', rel: 'Roommate', vehicle: 'Cybercab', miles: 3.9, status: 'confirmed' }];


// "For {name}" pill — marks a ride booked on behalf of someone else.
function RideForTag({ person, style }) {
  const first = (person?.name || '').trim().split(/\s+/)[0];
  if (!first) return null;
  return (
    <span style={{ flexShrink: 0, display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 10.5, fontWeight: 600, color: T.gold, background: `${T.gold}1a`, border: `0.5px solid ${T.gold}33`, padding: '2px 8px', borderRadius: 99, whiteSpace: 'nowrap', ...style }}>
      <SFIcon name="person.fill" size={9} color={T.gold} />For {first}
    </span>);

}

function RideHistoryScreen({ nav, setNav, riderName = 'Sam', onOpenRide }) {
  const S = useSurfaces();
  const [tab, setTab] = ssS('completed'); // completed | scheduled
  const [scheduled, setScheduled] = ssS(SCHEDULED_RIDES);
  const [activeRide, setActiveRide] = ssS(null); // scheduled ride open in the detail sheet

  const grouped = ssM(() => {
    const out = {};
    REQUESTED_RIDES.forEach((r) => {(out[r.day] = out[r.day] || []).push(r);});
    return out;
  }, []);
  const completedCount = REQUESTED_RIDES.length;
  const totalMiles = REQUESTED_RIDES.reduce((s, r) => s + r.miles, 0);
  const scheduledCount = scheduled.length;
  const confirmedCount = scheduled.filter((r) => r.status === 'confirmed').length;

  const reschedule = (id, day, time, date) => {
    setScheduled((list) => list.map((r) => r.id === id ? { ...r, day, time, date: date || r.date, status: 'pending' } : r));
    setActiveRide((a) => a && a.id === id ? { ...a, day, time, date: date || a.date, status: 'pending' } : a);
  };
  const cancelRide = (id) => {
    setScheduled((list) => list.filter((r) => r.id !== id));
    setActiveRide(null);
  };

  return (
    <div style={{ position: 'absolute', inset: 0, background: T.bg, display: 'flex', flexDirection: 'column' }}>
      {/* Header */}
      <div style={{ padding: '74px 24px 16px' }}>
        <div style={{ fontSize: 28, fontWeight: 600, color: T.text, letterSpacing: -0.6, marginBottom: 4 }}>Your rides</div>
        <div style={{ fontSize: 13, color: T.textSec, fontWeight: 400, fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums' }}>
          {tab === 'completed' ?
          <>{completedCount} trips · <span style={{ color: T.gold, fontWeight: 500 }}>{totalMiles.toFixed(1)} mi</span></> :
          <>{scheduledCount} scheduled · <span style={{ color: T.gold, fontWeight: 500 }}>{confirmedCount} confirmed</span></>}
        </div>
      </div>

      <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 104 }}>
        {/* Segmented control — completed history vs scheduled rides */}
        <div style={{ display: 'flex', gap: 3, margin: '0 24px 18px', padding: 3, borderRadius: 12, background: 'rgba(255,255,255,0.05)' }}>
          {[['completed', `Completed${completedCount ? ` · ${completedCount}` : ''}`], ['scheduled', `Scheduled${scheduledCount ? ` · ${scheduledCount}` : ''}`]].map(([k, label]) =>
          <button key={k} onClick={() => setTab(k)} style={{
            flex: 1, padding: '8px 6px', borderRadius: 9, border: 'none', cursor: 'pointer',
            fontFamily: T.font, fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
            background: tab === k ? T.gold : 'transparent', color: tab === k ? '#1a1408' : T.textSec,
            transition: 'background .18s, color .18s', WebkitTapHighlightColor: 'transparent'
          }}>{label}</button>
          )}
        </div>

        {tab === 'completed' ?
        <>
            {Object.entries(grouped).map(([day, items]) =>
          <div key={day} style={{ marginBottom: 16 }}>
                <div style={{ padding: '0 24px 10px' }}><Label>{day}</Label></div>
                {items.map((r) => <RequestedRideRow key={r.id} r={r} onClick={() => onOpenRide && onOpenRide(r)} />)}
              </div>
          )}
            <div style={{ textAlign: 'center', fontSize: 11, color: T.textMuted, padding: '8px 0 4px', letterSpacing: 0.2 }}>
              Rides you’ve requested from shared vehicles
            </div>
          </> :

        scheduledCount > 0 ?
        <div>
              {scheduled.map((r) => <ScheduledRideRow key={r.id} r={r} onClick={() => setActiveRide(r)} />)}
              <div style={{ textAlign: 'center', fontSize: 11, color: T.textMuted, padding: '8px 0 4px', letterSpacing: 0.2 }}>
                Tap a ride to view details or make changes
              </div>
            </div> :

        <div style={{ textAlign: 'center', padding: '48px 32px', color: T.textMuted }}>
              <div style={{ width: 52, height: 52, borderRadius: 26, background: 'rgba(255,255,255,0.04)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
                <SFIcon name="calendar" size={22} color={T.textMuted} />
              </div>
              <div style={{ fontSize: 14, color: T.textSec, fontWeight: 500 }}>No scheduled rides</div>
              <div style={{ fontSize: 12.5, color: T.textMuted, marginTop: 4, lineHeight: 1.45 }}>Rides you book for later will appear here.</div>
            </div>

        }
      </div>

      <BottomNav current={nav} onChange={setNav} tabs={SHARED_TABS} />

      <ScheduledRideSheet ride={activeRide} onClose={() => setActiveRide(null)}
      onReschedule={reschedule} onCancel={cancelRide} />
    </div>);

}

// Completed ride — elevated card matching the owner's DriveRow vocabulary.
function RequestedRideRow({ r, onClick }) {
  return (
    <div onClick={onClick} role="button" style={{
      margin: '0 24px 11px', padding: '15px 16px', borderRadius: 16, overflow: 'hidden', cursor: onClick ? 'pointer' : 'default',
      display: 'flex', flexDirection: 'column', gap: 12, WebkitTapHighlightColor: 'transparent',
      background: 'linear-gradient(122deg, rgba(255,255,255,0.05) 0%, rgba(255,255,255,0.022) 38%, rgba(255,255,255,0.012) 100%)',
      border: '0.5px solid rgba(255,255,255,0.09)',
      boxShadow: '0 1px 0 rgba(255,255,255,0.04) inset, 0 6px 20px rgba(0,0,0,0.28)'
    }}>
      {/* Route + time */}
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
        <div style={{ fontSize: 15, color: '#F2F2F2', fontWeight: 600, flex: 1, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          {r.from} <span style={{ color: T.textMuted, fontWeight: 400, margin: '0 3px' }}>→</span> {r.to}
        </div>
        <span style={{ fontFamily: T.fontNum, fontSize: 12, color: T.textMuted, fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>{r.start}</span>
      </div>

      {/* Driver + stats */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{ width: 26, height: 26, borderRadius: 13, background: T.elevated, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 600, color: T.text, flexShrink: 0, fontFamily: T.font }}>{r.driver[0]}</div>
        <span style={{ fontSize: 12.5, color: T.textSec, fontWeight: 400, flex: 1, minWidth: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          <span style={{ color: T.text, fontWeight: 500 }}>{r.driver}’s</span> {r.vehicle}
        </span>
        {r.for && <RideForTag person={r.for} />}
        <span style={{ fontFamily: T.fontNum, fontSize: 12, color: T.textMuted, fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>{r.miles.toFixed(1)} mi · {r.mins} min</span>
      </div>
    </div>);

}

// Scheduled ride — gold-tinted reservation card mirroring the owner's UpcomingRow.
function ScheduledRideRow({ r, onClick }) {
  const confirmed = r.status === 'confirmed';
  return (
    <div onClick={onClick} role="button" style={{
      margin: '0 24px 11px', padding: '15px 16px', borderRadius: 16, overflow: 'hidden', cursor: 'pointer',
      display: 'flex', flexDirection: 'column', gap: 12, WebkitTapHighlightColor: 'transparent',
      background: 'linear-gradient(122deg, rgba(201,168,76,0.10) 0%, rgba(201,168,76,0.03) 34%, rgba(255,255,255,0.018) 100%)',
      border: '0.5px solid rgba(201,168,76,0.20)',
      boxShadow: '0 1px 0 rgba(255,255,255,0.04) inset, 0 6px 20px rgba(0,0,0,0.28)'
    }}>
      {/* Date pill + route */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: 11, background: 'rgba(201,168,76,0.16)', border: '0.5px solid rgba(201,168,76,0.28)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <SFIcon name="calendar" size={16} color={T.gold} />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 15, fontWeight: 600, color: '#F4EFE2', letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {r.from} <span style={{ color: T.gold, fontWeight: 400 }}>→</span> {r.to}
          </div>
          <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 4, fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums' }}>
            <span style={{ color: T.gold, fontWeight: 600 }}>{r.day} {r.time}</span> · {r.miles.toFixed(1)} mi
          </div>
        </div>
        <SFIcon name="chevron.right" size={15} color="rgba(201,168,76,0.55)" />
      </div>

      {/* Driver + status */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{ width: 26, height: 26, borderRadius: 13, background: T.elevated, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 600, color: T.text, flexShrink: 0, fontFamily: T.font }}>{r.driver[0]}</div>
        <span style={{ fontSize: 12.5, color: T.textSec, fontWeight: 400, flex: 1, minWidth: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          <span style={{ color: T.text, fontWeight: 500 }}>{r.driver}’s</span> {r.vehicle}
        </span>
        {r.for && <RideForTag person={r.for} />}
        <span style={{
          flexShrink: 0, display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 11, fontWeight: 600, padding: '2px 9px', borderRadius: 99,
          background: confirmed ? 'rgba(48,209,88,0.16)' : 'rgba(255,255,255,0.07)',
          color: confirmed ? T.driving : T.textSec
        }}>
          <span style={{ width: 5, height: 5, borderRadius: 99, background: confirmed ? T.driving : T.textMuted }} />
          {confirmed ? 'Confirmed' : 'Pending'}
        </span>
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Scheduled-ride detail sheet — slides up over the ride list. Shows the
// reserved trip + lets the rider reschedule (day/time) or cancel.
// Mirrors the app's modal-sheet vocabulary (IncomingRequestSheet).
// ─────────────────────────────────────────────────────────────
const SCHED_DAYS = ['Today', 'Tomorrow', 'Thu', 'Fri', 'Sat', 'Sun', 'Mon'];
const SCHED_DATES = { Today: 'Jun 16', Tomorrow: 'Jun 17', Thu: 'Jun 18', Fri: 'Jun 19', Sat: 'Jun 20', Sun: 'Jun 21', Mon: 'Jun 22' };
const SCHED_TIMES = (() => {
  const out = [];
  for (let h = 6; h <= 22; h++) for (const m of [0, 30]) {
    const ap = h >= 12 ? 'PM' : 'AM';const hh = h % 12 || 12;
    out.push(`${hh}:${m === 0 ? '00' : '30'} ${ap}`);
  }
  return out;
})();

function ScheduledRideSheet({ ride, onClose, onReschedule, onCancel }) {
  const S = useSurfaces();
  const [mode, setMode] = ssS('details'); // details | reschedule | confirmCancel
  const [day, setDay] = ssS('Today');
  const [time, setTime] = ssS('5:30 PM');
  const route = ssM(() => buildSampleRoute(), [ride?.id]);

  // Reset to details + seed the picker whenever a new ride opens.
  ssE(() => {
    if (ride) {setMode('details');setDay(ride.day);setTime(ride.time);}
  }, [ride?.id]);

  if (!ride) return null;
  const confirmed = ride.status === 'confirmed';
  const mins = Math.max(6, Math.round(ride.miles * 1.7));
  const dirty = day !== ride.day || time !== ride.time;

  return (
    <div style={{
      position: 'absolute', inset: 0, zIndex: 60,
      display: 'flex', flexDirection: 'column', justifyContent: 'flex-end'
    }}>
      {/* Scrim */}
      <div onClick={onClose} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.55)', animation: 'mrt-fade-up .22s ease-out both' }} />

      {/* Sheet */}
      <div style={{
        position: 'relative',
        borderTopLeftRadius: S.modalRadius, borderTopRightRadius: S.modalRadius,
        padding: '14px 24px 30px', maxHeight: '88%', overflowY: 'auto',
        animation: 'mrt-sched-up .34s cubic-bezier(.32,.72,0,1) both',
        ...S.modalSheet
      }} data-comment-anchor="7fa5bf0a9d-div-244-7">
        <div style={{ width: 36, height: 4, background: T.elevated, borderRadius: 4, margin: '0 auto 16px' }} />

        {/* Close */}
        <button onClick={onClose} aria-label="Close" style={{
          position: 'absolute', top: 16, right: 18, width: 28, height: 28, borderRadius: 14,
          background: T.elevated, border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 4
        }}>
          <SFIcon name="xmark" size={11} color={T.textSec} weight={2} />
        </button>

        {mode === 'confirmCancel' ?
        <div style={{ textAlign: 'center', padding: '6px 4px 0' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="calendar" size={20} color="#FF6B6B" />
            </div>
            <div style={{ fontSize: 18, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Cancel this ride?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 22, maxWidth: 280, margin: '0 auto 22px' }}>
              Your reservation to <span style={{ color: T.text, fontWeight: 600 }}>{ride.to}</span> on {ride.day} {ride.time} with {ride.driver}’s {ride.vehicle} will be released.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <Button variant="outline-muted" onClick={() => onCancel(ride.id)} style={{ background: 'rgba(255,59,48,0.14)', color: '#FF6B6B', border: '0.5px solid rgba(255,59,48,0.40)' }}>Cancel ride</Button>
              <Button variant="ghost" onClick={() => setMode('details')}>Keep reservation</Button>
            </div>
          </div> :
        mode === 'reschedule' ?
        <div>
            <button onClick={() => setMode('details')} style={{ display: 'inline-flex', alignItems: 'center', gap: 3, padding: '2px 8px 12px 0', background: 'transparent', border: 'none', cursor: 'pointer', color: T.gold, fontFamily: T.font, fontSize: 13, fontWeight: 600, letterSpacing: -0.1 }}>
              <SFIcon name="chevron.left" size={13} color={T.gold} /><span>Back</span>
            </button>
            <div style={{ fontSize: 20, fontWeight: 600, color: T.text, letterSpacing: -0.4, marginBottom: 4 }}>Reschedule pickup</div>
            <div style={{ fontSize: 13, color: T.textSec, marginBottom: 20, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{ride.from} → {ride.to}</div>

            <div style={{ fontSize: 10.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase', marginBottom: 9 }}>Day</div>
            <div className="mrt-noscroll" style={{ display: 'flex', gap: 7, overflowX: 'auto', marginBottom: 20, paddingBottom: 2 }}>
              {SCHED_DAYS.map((d) =>
            <button key={d} onClick={() => setDay(d)} style={{
              flexShrink: 0, padding: '9px 15px', borderRadius: 12, cursor: 'pointer',
              border: day === d ? '0.5px solid transparent' : `0.5px solid ${T.border}`,
              background: day === d ? T.gold : 'rgba(255,255,255,0.04)',
              color: day === d ? '#1a1408' : T.textSec,
              fontFamily: T.font, fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1, whiteSpace: 'nowrap'
            }}>{d}</button>
            )}
            </div>

            <div style={{ fontSize: 10.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase', marginBottom: 9 }}>Time</div>
            <div className="mrt-noscroll" style={{ display: 'flex', gap: 7, overflowX: 'auto', marginBottom: 22, paddingBottom: 2 }}>
              {SCHED_TIMES.map((t) =>
            <button key={t} onClick={() => setTime(t)} style={{
              flexShrink: 0, padding: '9px 14px', borderRadius: 12, cursor: 'pointer',
              border: time === t ? '0.5px solid transparent' : `0.5px solid ${T.border}`,
              background: time === t ? T.gold : 'rgba(255,255,255,0.04)',
              color: time === t ? '#1a1408' : T.textSec,
              fontFamily: T.fontNum, fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums'
            }}>{t}</button>
            )}
            </div>

            <Button variant={dirty ? 'gold' : 'outline-muted'} onClick={() => {if (dirty) {onReschedule(ride.id, day, time, SCHED_DATES[day]);setMode('requested');} else {setMode('details');}}}>
              {dirty ? `Move to ${day} ${time}` : 'No changes'}
            </Button>
            <div style={{ fontSize: 11.5, color: T.textMuted, textAlign: 'center', marginTop: 12, letterSpacing: 0.1 }}>
              {ride.driver} will be asked to re-confirm the new time.
            </div>
          </div> :
        mode === 'requested' ?
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '10px 0 0' }}>
            <div style={{ width: 74, height: 74, position: 'relative', marginBottom: 20 }}>
              <div style={{ position: 'absolute', inset: 0, borderRadius: 38, border: `2px solid ${T.gold}`, animation: 'mrt-ping 1.4s ease-out infinite', opacity: 0.4 }} />
              <div style={{ position: 'absolute', inset: 10, borderRadius: 28, border: `2px solid ${T.gold}`, animation: 'mrt-ping 1.4s ease-out infinite 0.4s', opacity: 0.5 }} />
              <div style={{ position: 'absolute', inset: 22, borderRadius: 16, background: T.gold, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: `0 0 24px ${T.gold}99` }}>
                <SFIcon name="calendar" size={15} color="#1a1408" />
              </div>
            </div>
            <div style={{ fontSize: 18, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 7 }}>Reschedule requested</div>
            <div style={{ fontSize: 13, color: T.textSec, textAlign: 'center', lineHeight: 1.45, marginBottom: 16, maxWidth: 270 }}>
              Waiting for <span style={{ color: T.text, fontWeight: 500 }}>{ride.driver}</span> to confirm the new pickup time.
            </div>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '9px 15px', borderRadius: 12, background: 'rgba(201,168,76,0.12)', border: `0.5px solid ${T.gold}40`, marginBottom: 22 }}>
              <SFIcon name="calendar" size={13} color={T.gold} />
              <span style={{ fontFamily: T.fontNum, fontSize: 14, fontWeight: 600, color: T.gold, letterSpacing: -0.1, fontVariantNumeric: 'tabular-nums' }}>{ride.day} · {ride.time}</span>
            </div>
            <Button variant="gold" onClick={onClose}>Done</Button>
            <div style={{ fontSize: 11.5, color: T.textMuted, textAlign: 'center', marginTop: 12, letterSpacing: 0.1 }}>
              {ride.for ?
            `You and ${ride.for.name.trim().split(/\s+/)[0]} get the updated time once ${ride.driver} responds.` :
            `You’ll be notified once ${ride.driver} responds.`}
            </div>
          </div> :

        <div>
            {/* Status row */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }} data-comment-anchor="92a6e87d31-div-328-13">
              <span style={{ fontSize: 10, color: T.gold, letterSpacing: 1.2, fontWeight: 700, textTransform: 'uppercase' }}>Scheduled ride</span>
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 11, fontWeight: 600, color: confirmed ? T.driving : T.textSec }}>
                <span style={{ width: 5, height: 5, borderRadius: 99, background: confirmed ? T.driving : T.textMuted }} />
                {confirmed ? 'Confirmed' : 'Pending confirmation'}
              </span>
            </div>

            {/* Map preview */}
            <div style={{ borderRadius: 16, overflow: 'hidden', border: `0.5px solid ${T.border}`, marginBottom: 14, position: 'relative', height: 104 }}>
              <MapBackground width={402} height={104} seed={ride.id.charCodeAt(1) * 7} />
              <svg width="402" height="104" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
                <RouteLine path={route} progress={1} width={5} glow />
                <EndpointDot x={route[0][0]} y={route[0][1]} color={T.driving} size={11} />
                <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={13} />
              </svg>
              <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(180deg, transparent 32%, rgba(20,20,22,0.92) 100%)' }} />
              <div style={{ position: 'absolute', bottom: 11, left: 14, right: 14, display: 'flex', alignItems: 'center', gap: 8 }}>
                <SFIcon name="calendar" size={14} color={T.gold} />
                <span style={{ fontFamily: T.fontNum, fontSize: 14, fontWeight: 600, color: '#F4EFE2', letterSpacing: -0.2, fontVariantNumeric: 'tabular-nums' }}>{ride.day} · {ride.time}</span>
              </div>
            </div>

            {/* Route block */}
            <div style={{ borderRadius: 16, padding: '4px 16px 12px', marginBottom: 12, ...S.inner }}>
              <div style={{ display: 'flex', alignItems: 'stretch', gap: 13 }}>
                <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', paddingTop: 18, paddingBottom: 18, flexShrink: 0 }}>
                  <span style={{ width: 9, height: 9, borderRadius: 5, background: T.driving, boxShadow: `0 0 7px ${T.driving}aa` }} />
                  <span style={{ flex: 1, width: 2, margin: '4px 0', background: `repeating-linear-gradient(${T.border} 0 3px, transparent 3px 6px)` }} />
                  <span style={{ width: 9, height: 9, borderRadius: 2.5, background: T.gold, boxShadow: `0 0 7px ${T.gold}aa` }} />
                </div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ padding: '11px 0' }}>
                    <div style={{ fontSize: 9.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase' }}>Pickup</div>
                    <div style={{ fontSize: 14.5, color: T.text, fontWeight: 500, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{ride.from}</div>
                  </div>
                  <div style={{ height: '0.5px', background: T.border }} />
                  <div style={{ padding: '11px 0' }}>
                    <div style={{ fontSize: 9.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase' }}>Destination</div>
                    <div style={{ fontSize: 14.5, color: T.text, fontWeight: 500, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{ride.to}</div>
                  </div>
                </div>
              </div>
              {/* Trip stats footer */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 18, paddingLeft: 22, paddingTop: 11, borderTop: `0.5px solid ${T.border}`, fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums' }}>
                <div>
                  <span style={{ fontSize: 9.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase', marginRight: 7 }}>Distance</span>
                  <span style={{ fontSize: 13, color: T.text, fontWeight: 600 }}>{ride.miles.toFixed(1)} mi</span>
                </div>
                <div>
                  <span style={{ fontSize: 9.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase', marginRight: 7 }}>Drive</span>
                  <span style={{ fontSize: 13, color: T.text, fontWeight: 600 }}>{mins} min</span>
                </div>
              </div>
            </div>

            {/* People — owner's vehicle + (optional) passenger on one surface
               so the gray/gold treatments don't compete. Gold is text-only here. */}
            <div style={{ borderRadius: 13, marginBottom: 16, overflow: 'hidden', ...S.inner }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 13px' }}>
                <div style={{ width: 34, height: 34, borderRadius: 17, background: T.elevated, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13.5, fontWeight: 600, color: T.text, flexShrink: 0, fontFamily: T.font }}>{ride.driver[0]}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 14, fontWeight: 600, color: T.text, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{ride.driver}’s {ride.vehicle}</div>
                  <div style={{ fontSize: 11.5, color: T.textSec, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }} data-comment-anchor="0f73edbd35-div-383-17">{ride.rel} · Shared with you</div>
                </div>
                <SFIcon name="car.fill" size={15} color={T.textMuted} />
              </div>
              {ride.for &&
            <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 13px', borderTop: `0.5px solid ${T.border}` }}>
                  <div style={{ width: 34, height: 34, borderRadius: 17, background: `${T.gold}22`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 600, color: T.gold, flexShrink: 0, fontFamily: T.font }}>{ride.for.name.trim().split(/\s+/).map((s) => s[0]).slice(0, 2).join('').toUpperCase()}</div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 7, minWidth: 0 }}>
                      <span style={{ flex: 1, minWidth: 0, fontSize: 14, fontWeight: 600, color: T.text, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{ride.for.name}</span>
                      <span style={{ flexShrink: 0, fontSize: 9.5, fontWeight: 700, letterSpacing: 0.6, color: T.gold, background: `${T.gold}1f`, padding: '2px 7px', borderRadius: 99, textTransform: 'uppercase' }}>Passenger</span>
                    </div>
                    {ride.for.phone && <div style={{ fontSize: 11.5, color: T.textSec, marginTop: 2, fontFamily: T.fontNum, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{ride.for.phone} · {confirmed ? 'has tracking link' : 'gets link on confirm'}</div>}
                  </div>
                  <SFIcon name="person.fill" size={15} color={T.textMuted} />
                </div>
          }
            </div>

            {/* Modify actions */}
            <div style={{ display: 'flex', gap: 10, marginBottom: 11 }}>
              <Button variant="outline-muted" onClick={() => setMode('confirmCancel')} style={{ color: '#FF6B6B' }}>Cancel ride</Button>
              <Button variant="outline-draw" onClick={() => setMode('reschedule')}><span className="mrt-gold-pulse">Reschedule</span></Button>
            </div>
            <div style={{ fontSize: 11.5, color: T.textMuted, textAlign: 'center', letterSpacing: 0.1 }}>
              Changes notify {ride.driver} to re-confirm.
            </div>
          </div>
        }
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Shared-viewer settings — lightweight: profile, shared vehicles,
// notifications, sign out. No vehicle-control access.
// ─────────────────────────────────────────────────────────────
function SharedSettingsScreen({ nav, setNav, riderName = 'Sam', onAddCode, onSignOut }) {
  const S = useSurfaces();
  const [confirmSignOut, setConfirmSignOut] = ssS(false);
  const [toggles, setT] = ssS({ requestUpdates: true, arrival: true, promos: false });
  const tog = (k) => setT((s) => ({ ...s, [k]: !s[k] }));
  const firstName = (riderName || 'Sam').trim().split(/\s+/)[0];
  const fullName = /\s/.test((riderName || '').trim()) ? riderName.trim() : `${firstName} Rivera`;
  const email = `${firstName.toLowerCase()}.rivera@gmail.com`;

  const sharedWith = [
  { owner: 'Alex', rel: 'Roommate', vehicle: 'Cybercab', access: 'Request rides' },
  { owner: 'Mom', rel: 'Family', vehicle: 'Model Y', access: 'Request rides' },
  { owner: 'Jordan', rel: 'Friend', vehicle: 'Model 3', access: 'Request rides' }];


  return (
    <div style={{ position: 'absolute', inset: 0, background: T.bg, display: 'flex', flexDirection: 'column' }}>
      <div style={{ padding: '74px 24px 12px' }}>
        <div style={{ fontSize: 28, fontWeight: 600, color: T.text, letterSpacing: -0.6 }}>Settings</div>
      </div>

      <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 104 }}>
        {/* Profile */}
        <div style={{ margin: '0 24px 22px', padding: '16px', borderRadius: S.cardRadius, display: 'flex', alignItems: 'center', gap: 13, ...S.card }}>
          <div style={{ width: 48, height: 48, borderRadius: 24, background: `radial-gradient(circle at 30% 30%, ${T.gold}, #8a6f28)`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 19, fontWeight: 600, color: '#1a1408', flexShrink: 0, fontFamily: T.font }}>{firstName[0]}</div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3 }}>{fullName}</div>
            <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 2 }}>{email}</div>
          </div>
          <span style={{ fontSize: 11, fontWeight: 600, color: T.gold, background: `${T.gold}1f`, padding: '4px 10px', borderRadius: 99, flexShrink: 0 }}>Guest</span>
        </div>

        {/* Shared with me */}
        <div style={{ padding: '0 24px 8px' }}><Label>Shared with me</Label></div>
        <div style={{ margin: '0 24px 22px', borderRadius: S.cardRadius, overflow: 'hidden', ...S.card }}>
          {sharedWith.map((v, i) =>
          <div key={v.owner} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 16px', borderTop: i === 0 ? 'none' : `0.5px solid ${T.border}` }}>
              <div style={{ width: 32, height: 32, borderRadius: 16, background: T.elevated, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 600, color: T.text, flexShrink: 0, fontFamily: T.font }}>{v.owner[0]}</div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14, fontWeight: 500, color: T.text, letterSpacing: -0.1 }}>{v.owner}’s {v.vehicle}</div>
                <div style={{ fontSize: 11.5, color: T.textSec, marginTop: 2 }}>{v.rel} · {v.access}</div>
              </div>
              <SFIcon name="car.fill" size={15} color={T.textMuted} />
            </div>
          )}
          {/* Add another invite code */}
          <button onClick={onAddCode} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 16px', width: '100%', textAlign: 'left', background: 'transparent', border: 'none', borderTop: `0.5px solid ${T.border}`, cursor: 'pointer', WebkitTapHighlightColor: 'transparent' }}>
            <div style={{ width: 32, height: 32, borderRadius: 16, background: `${T.gold}1f`, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
              <SFIcon name="plus" size={15} color={T.gold} weight={2.2} />
            </div>
            <span style={{ flex: 1, fontSize: 14, fontWeight: 600, color: T.gold, letterSpacing: -0.1 }}>Enter invite code</span>
            <SFIcon name="chevron.right" size={13} color={T.textMuted} />
          </button>
        </div>

        {/* Notifications */}
        <div style={{ padding: '0 24px 8px' }}><Label>Notifications</Label></div>
        <div style={{ margin: '0 24px 22px', borderRadius: S.cardRadius, overflow: 'hidden', ...S.card }}>
          {[
          ['requestUpdates', 'Request accepted / declined'],
          ['arrival', 'Pick-up & arrival alerts'],
          ['promos', 'Tips & product news']].
          map(([k, label], i) =>
          <div key={k} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 16px', borderTop: i === 0 ? 'none' : `0.5px solid ${T.border}` }}>
              <span style={{ flex: 1, fontSize: 14, color: T.text, fontWeight: 400, letterSpacing: -0.1 }}>{label}</span>
              <Toggle value={toggles[k]} onChange={() => tog(k)} />
            </div>
          )}
        </div>

        {/* Sign out */}
        <div style={{ margin: '0 24px' }}>
          <button onClick={() => setConfirmSignOut(true)} style={{
            width: '100%', padding: '14px', borderRadius: S.cardRadius,
            background: 'transparent', border: `0.5px solid ${T.border}`,
            color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 500, cursor: 'pointer',
            WebkitTapHighlightColor: 'transparent'
          }}>Sign out</button>
        </div>
        <div style={{ textAlign: 'center', fontSize: 11, color: T.textMuted, padding: '16px 0 4px' }}>MyRoboTaxi · Guest access</div>
      </div>

      {/* Sign-out confirmation */}
      {confirmSignOut && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 80, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 28 }}>
          <div onClick={() => setConfirmSignOut(false)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.6)', animation: 'mrt-fade-up .2s ease-out both' }}/>
          <div style={{ position: 'relative', width: '100%', maxWidth: 300, borderRadius: 22, padding: '22px 20px 18px', background: '#1a1a1c', border: `0.5px solid ${T.border}`, boxShadow: '0 20px 60px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .28s cubic-bezier(.32,.72,0,1) both', textAlign: 'center' }}>
            <div style={{ width: 46, height: 46, borderRadius: 23, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 14px' }}>
              <SFIcon name="arrow.up.right" size={20} color="#FF6B6B"/>
            </div>
            <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Sign out?</div>
            <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>
              You'll need an invite code to rejoin. The vehicles shared with you stay available when you sign back in.
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              <button onClick={() => { setConfirmSignOut(false); onSignOut && onSignOut(); }} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: 'none', cursor: 'pointer',
                background: 'rgba(255,59,48,0.16)', color: '#FF6B6B', fontFamily: T.font, fontSize: 15, fontWeight: 600,
                WebkitTapHighlightColor: 'transparent',
              }}>Sign out</button>
              <button onClick={() => setConfirmSignOut(false)} style={{
                width: '100%', padding: '13px', borderRadius: 13, border: `0.5px solid ${T.border}`, cursor: 'pointer',
                background: 'transparent', color: T.text, fontFamily: T.font, fontSize: 15, fontWeight: 500,
                WebkitTapHighlightColor: 'transparent',
              }}>Cancel</button>
            </div>
          </div>
        </div>
      )}

      <BottomNav current={nav} onChange={setNav} tabs={SHARED_TABS} />
    </div>);

}

Object.assign(window, { RideHistoryScreen, SharedSettingsScreen, REQUESTED_RIDES, SCHEDULED_RIDES });