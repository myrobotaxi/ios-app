// Ride request feature — overlay surfaces.
//
// Viewer-side flow lives as an EXPANDING BOTTOM SHEET inside the shared
// viewer's map screen — phases switch the sheet content + height.
// Owner-side surface is a modal sheet that overlays any owner screen.
//
// Exports:
//   ExpandingRequestSheet({ phase, ... })  — viewer-side, growing sheet
//   IncomingRequestSheet({ visible, ... }) — owner-side, modal sheet
//   RouteSentToast({ visible, ... })       — owner-side, top toast
//   SAVED_PLACES, RECENT_PLACES

const { useState: rrS, useEffect: rrE, useMemo: rrM, useRef: rrR } = React;

const SAVED_PLACES = [
{ id: 'home', label: 'Home', sub: '221 Folsom St, San Francisco', icon: 'house.fill', iconColor: '#7AA2F7', miles: 4.2, mins: 18 },
{ id: 'work', label: 'Work', sub: '88 Marina Blvd, San Francisco', icon: 'briefcase.fill', iconColor: '#9D7CFF', miles: 5.1, mins: 22 },
{ id: 'gym', label: 'Equinox SoMa', sub: '301 Mission St', icon: 'figure.run', iconColor: '#FF6B9E', miles: 0.9, mins: 7 }];


const RECENT_PLACES = [
{ id: 'tartine', label: 'Tartine Bakery', sub: '600 Guerrero St · Mission', miles: 3.1, mins: 14 },
{ id: 'sfo', label: 'SFO · Terminal 2', sub: 'San Francisco International', miles: 18.4, mins: 32 },
{ id: 'ferrybldg', label: 'Ferry Building', sub: '1 Ferry Building · Embarcadero', miles: 0.6, mins: 6 },
{ id: 'pescadero', label: "Duarte's Tavern", sub: '202 Stage Rd · Pescadero', miles: 41.2, mins: 87 },
{ id: 'pier39', label: 'Pier 39', sub: 'Beach St · Wharf', miles: 2.1, mins: 11 }];


const SUGGESTED_NEARBY = [
{ id: 'beach', label: 'Ocean Beach', cat: 'Beach', miles: 8.4, mins: 24 },
{ id: 'park', label: 'Crissy Field', cat: 'Park', miles: 4.6, mins: 16 },
{ id: 'museum', label: 'SFMOMA', cat: 'Museum', miles: 1.2, mins: 8 }];


// People the rider has previously booked rides for (quick-pick when requesting for someone else).
const RECENT_PASSENGERS = [
{ name: 'Maya Chen', phone: '(415) 555-0142' },
{ name: 'Dad', phone: '(415) 555-0193' },
{ name: 'Priya Rao', phone: '(415) 555-0178' }];


// Sheet snap heights (px, measured from the bottom of the phone)
const SHEET_HEIGHTS = {
  idleParked: 434,
  idleDriving: 358,
  search: 712,
  review: 432,
  pending: 420,
  outcome: 410,
  tracking: 360,
  pinDrop: 280
};

// ─────────────────────────────────────────────────────────────
// Destination row (used inside search content)
// ─────────────────────────────────────────────────────────────
function DestRow({ icon, iconColor, label, sub, miles, mins, onSelect }) {
  return (
    <button onClick={onSelect} style={{
      display: 'flex', alignItems: 'center', gap: 14, width: '100%',
      padding: '12px 0', border: 'none', background: 'transparent',
      borderBottom: `0.5px solid ${T.border}`, cursor: 'pointer',
      WebkitTapHighlightColor: 'transparent', textAlign: 'left'
    }}>
      <div style={{
        width: 34, height: 34, borderRadius: 9, flexShrink: 0,
        background: icon ? `${iconColor || T.gold}1A` : T.elevated,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        border: `0.5px solid ${(iconColor || T.gold) + '33'}`
      }}>
        {icon ?
        <SFIcon name={icon} size={15} color={iconColor || T.gold} /> :
        <SFIcon name="mappin" size={15} color={T.textSec} />}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 14, fontWeight: 500, color: T.text, letterSpacing: -0.1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{label}</div>
        <div style={{ fontSize: 11.5, color: T.textSec, marginTop: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{sub}</div>
      </div>
      {miles != null &&
      <div style={{ textAlign: 'right', fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>
          <div style={{ fontSize: 12.5, color: T.text, fontWeight: 500 }}>{miles.toFixed(1)} mi</div>
          <div style={{ fontSize: 10.5, color: T.textMuted, marginTop: 1 }}>{mins} min</div>
        </div>
      }
    </button>);

}

// ─────────────────────────────────────────────────────────────
// Passenger picker — shown when requesting a ride FOR someone else.
// Quick-pick recent contacts or enter a name + mobile; the number is how
// we text them the live tracking link once the owner accepts.
// ─────────────────────────────────────────────────────────────
function PassengerPicker({ passenger, setPassenger, requesterName = 'Alex' }) {
  const S = useSurfaces();
  const set = setPassenger || (() => {});
  const name = passenger?.name || '';
  const phone = passenger?.phone || '';
  const firstName = name.trim().split(/\s+/)[0];
  const initials = (n) => n.trim().split(/\s+/).map((s) => s[0]).slice(0, 2).join('').toUpperCase();
  const fieldStyle = {
    width: '100%', background: 'rgba(255,255,255,0.05)', border: `0.5px solid ${T.border}`,
    borderRadius: 10, padding: '11px 12px', color: T.text, fontFamily: T.font, fontSize: 14,
    fontWeight: 500, letterSpacing: -0.1, outline: 'none', WebkitTapHighlightColor: 'transparent', boxSizing: 'border-box'
  };
  return (
    <div style={{ borderRadius: 16, padding: '13px 14px', marginBottom: 12, flexShrink: 0, ...S.inner }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
        <span style={{ fontSize: 9.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase' }}>Passenger</span>
        {name &&
        <button onClick={() => set(null)} style={{ background: 'transparent', border: 'none', cursor: 'pointer', color: T.gold, fontFamily: T.font, fontSize: 12, fontWeight: 600, padding: 0 }}>Clear</button>
        }
      </div>
      {/* Recent contacts */}
      <div className="mrt-noscroll" style={{ display: 'flex', gap: 8, overflowX: 'auto', marginBottom: 11, paddingBottom: 2 }}>
        {RECENT_PASSENGERS.map((p) => {
          const active = phone === p.phone;
          return (
            <button key={p.phone} onClick={() => set({ name: p.name, phone: p.phone })} style={{
              flexShrink: 0, display: 'flex', alignItems: 'center', gap: 8, padding: '6px 12px 6px 6px', borderRadius: 999, cursor: 'pointer',
              background: active ? 'rgba(201,168,76,0.16)' : 'rgba(255,255,255,0.05)',
              border: `0.5px solid ${active ? T.gold + '66' : T.border}`, WebkitTapHighlightColor: 'transparent'
            }}>
              <span style={{ width: 24, height: 24, borderRadius: 12, background: T.elevated, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 10.5, fontWeight: 600, color: T.text, fontFamily: T.font }}>{initials(p.name)}</span>
              <span style={{ fontSize: 13, fontWeight: 600, color: active ? T.gold : T.text, letterSpacing: -0.1, whiteSpace: 'nowrap' }}>{p.name}</span>
            </button>);

        })}
      </div>
      {/* Inputs */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        <input value={name} onChange={(e) => set({ name: e.target.value, phone })} placeholder="Passenger name" style={fieldStyle} />
        <input value={phone} onChange={(e) => set({ name, phone: e.target.value })} placeholder="Mobile number" inputMode="tel" style={{ ...fieldStyle, fontFamily: T.fontNum }} />
      </div>
      {/* Notify note */}
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8, marginTop: 11 }}>
        <span style={{ flexShrink: 0, marginTop: 1 }}><SFIcon name="paperplane.fill" size={12} color={T.gold} /></span>
        <span style={{ fontSize: 11.5, color: T.textSec, letterSpacing: -0.1, lineHeight: 1.35 }}>
          We’ll text {firstName ? <span style={{ color: T.text, fontWeight: 600 }}>{firstName}</span> : 'them'} a live tracking link as soon as {requesterName} accepts.
        </span>
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Search content (lives inside sheet, no header chrome — sheet already
// has handle + close button)
// ─────────────────────────────────────────────────────────────
function SearchContent({ vehicleName, requesterName = 'Alex', onSelect, autoFocus = true, schedule, setSchedule, rider = 'me', setRider, passenger, setPassenger, pickup, onPickOnMap }) {
  const S = useSurfaces();
  const [q, setQ] = rrS('');
  const [schedOpen, setSchedOpen] = rrS(false);
  const [schedDay, setSchedDay] = rrS(schedule?.day || 'Today');
  const [schedTime, setSchedTime] = rrS(schedule?.time || '5:30 PM');
  const inputRef = rrR(null);
  rrE(() => {if (autoFocus) setTimeout(() => inputRef.current?.focus(), 250);}, [autoFocus]);

  const DAYS = ['Today', 'Tomorrow', 'Thu', 'Fri', 'Sat', 'Sun', 'Mon'];
  const TIMES = (() => {
    const out = [];
    for (let h = 7; h <= 22; h++) {
      for (const m of [0, 30]) {
        const ap = h >= 12 ? 'PM' : 'AM';
        const hh = h % 12 || 12;
        out.push(`${hh}:${m === 0 ? '00' : '30'} ${ap}`);
      }
    }
    return out;
  })();

  const openSchedule = () => {setSchedOpen(true);};
  const confirmSchedule = () => {setSchedule({ day: schedDay, time: schedTime });setSchedOpen(false);};

  const filtered = q ?
  RECENT_PLACES.filter((p) => p.label.toLowerCase().includes(q.toLowerCase()) || p.sub.toLowerCase().includes(q.toLowerCase())) :
  null;

  const pickupLabel = pickup?.label || 'Current location';

  // Compact filter chip
  const Chip = ({ active, onClick, children }) =>
  <button onClick={onClick} style={{
    padding: '7px 14px', borderRadius: 999, cursor: 'pointer',
    border: active ? '0.5px solid transparent' : `0.5px solid ${T.border}`,
    background: active ? T.gold : 'rgba(255,255,255,0.04)',
    color: active ? '#1a1408' : T.textSec,
    fontFamily: T.font, fontSize: 13, fontWeight: 600, letterSpacing: -0.1,
    whiteSpace: 'nowrap', WebkitTapHighlightColor: 'transparent',
    transition: 'background .18s, color .18s'
  }}>{children}</button>;


  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0, position: 'relative' }}>
      {/* When + For — chip selectors above the route (stable labels, no reflow) */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginBottom: schedule ? 8 : 12, flexShrink: 0, flexWrap: 'wrap' }}>
        <Chip active={!schedule} onClick={() => setSchedule(null)}>Now</Chip>
        <Chip active={!!schedule} onClick={openSchedule}>Schedule</Chip>
        <span style={{ width: 1, height: 16, background: T.border, margin: '0 3px' }} />
        <Chip active={rider === 'me'} onClick={() => {setRider && setRider('me');setPassenger && setPassenger(null);}}>Me</Chip>
        <Chip active={rider === 'other'} onClick={() => setRider && setRider('other')}>Someone else</Chip>
      </div>
      {schedule &&
      <button onClick={() => setSchedOpen(true)} style={{ display: 'flex', alignItems: 'center', gap: 7, marginBottom: 12, padding: 0, background: 'transparent', border: 'none', cursor: 'pointer', flexShrink: 0 }}>
          <SFIcon name="calendar" size={13} color={T.gold} />
          <span style={{ fontSize: 12.5, color: T.textSec, letterSpacing: -0.1 }}>Pickup <span style={{ color: T.text, fontWeight: 600 }}>{schedule.day} · {schedule.time}</span></span>
          <span style={{ fontSize: 12, color: T.gold, fontWeight: 600 }}>Edit</span>
        </button>
      }
      {rider === 'other' &&
      <PassengerPicker passenger={passenger} setPassenger={setPassenger} requesterName={requesterName} />
      }

      {/* Route: pickup → destination */}
      <div style={{ borderRadius: 16, padding: '4px 16px', marginBottom: 10, flexShrink: 0, ...S.inner }}>
        <div style={{ display: 'flex', alignItems: 'stretch', gap: 13 }}>
          {/* Connector rail */}
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', paddingTop: 19, paddingBottom: 19, flexShrink: 0 }}>
            <span style={{ width: 9, height: 9, borderRadius: 5, background: T.driving, boxShadow: `0 0 7px ${T.driving}aa` }} />
            <span style={{ flex: 1, width: 2, margin: '4px 0', background: `repeating-linear-gradient(${T.border} 0 3px, transparent 3px 6px)` }} />
            <span style={{ width: 9, height: 9, borderRadius: 2.5, background: T.gold, boxShadow: `0 0 7px ${T.gold}aa` }} />
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            {/* Pickup */}
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, padding: '11px 0' }}>
              <div style={{ minWidth: 0 }}>
                <div style={{ fontSize: 9.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase' }}>Pickup</div>
                <div style={{ fontSize: 14.5, color: T.text, fontWeight: 500, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{pickupLabel}</div>
              </div>
              <button onClick={onPickOnMap} style={{
                display: 'flex', alignItems: 'center', gap: 4, flexShrink: 0,
                background: pickup ? 'rgba(201,168,76,0.16)' : 'transparent',
                border: `0.5px solid ${pickup ? T.gold + '66' : T.border}`,
                borderRadius: 999, padding: '5px 10px', cursor: 'pointer',
                color: T.gold, fontFamily: T.font, fontSize: 11.5, fontWeight: 600, letterSpacing: -0.1, whiteSpace: 'nowrap'
              }}>
                <SFIcon name="mappin" size={11} color={T.gold} />
                <span>{pickup ? 'On map' : 'Set on map'}</span>
              </button>
            </div>
            <div style={{ height: '0.5px', background: T.border }} />
            {/* Destination input */}
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 0' }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 9.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase' }}>Destination</div>
                <input ref={inputRef} value={q} onChange={(e) => setQ(e.target.value)}
                placeholder="Where to?" style={{
                  width: '100%', background: 'transparent', border: 'none', outline: 'none',
                  color: T.text, fontFamily: T.font, fontSize: 14.5, fontWeight: 500,
                  letterSpacing: -0.1, marginTop: 2, padding: 0
                }} />
              </div>
              {q && <button onClick={() => setQ('')} style={{ background: 'transparent', border: 'none', cursor: 'pointer', padding: 0, display: 'flex', flexShrink: 0 }}>
                <SFIcon name="xmark" size={13} color={T.textMuted} />
              </button>}
            </div>
          </div>
        </div>
      </div>

      <div className="mrt-noscroll" style={{ flex: 1, overflowY: 'auto', minHeight: 0, paddingBottom: 16 }}>
        {filtered ?
        filtered.length === 0 ?
        <div style={{ padding: '32px 0', textAlign: 'center', fontSize: 13, color: T.textMuted }}>
              No results for "{q}"
            </div> :

        <div>
              <Label style={{ margin: '6px 0 0' }}>Results</Label>
              {filtered.map((p) => <DestRow key={p.id} label={p.label} sub={p.sub} miles={p.miles} mins={p.mins} onSelect={() => onSelect(p)} />)}
            </div> :


        <>
            <Label style={{ margin: '6px 0 0' }}>Saved</Label>
            {SAVED_PLACES.map((p) => <DestRow key={p.id} {...p} onSelect={() => onSelect(p)} />)}

            <Label style={{ margin: '18px 0 0' }}>Recent</Label>
            {RECENT_PLACES.slice(0, 4).map((p) => <DestRow key={p.id} label={p.label} sub={p.sub} miles={p.miles} mins={p.mins} onSelect={() => onSelect(p)} />)}

            <Label style={{ margin: '18px 0 8px' }}>Nearby</Label>
            <div className="mrt-noscroll" style={{ display: 'flex', gap: 8, overflowX: 'auto', padding: '2px 0 4px', margin: '0 -4px' }}>
              {SUGGESTED_NEARBY.map((p) =>
            <button key={p.id} onClick={() => onSelect(p)} style={{
              flexShrink: 0, padding: '12px 14px',
              borderRadius: 14, textAlign: 'left',
              cursor: 'pointer', minWidth: 132, ...S.inner
            }}>
                  <div style={{ fontSize: 10, color: T.textMuted, letterSpacing: 0.8, fontWeight: 500, textTransform: 'uppercase' }}>{p.cat}</div>
                  <div style={{ fontSize: 14, color: T.text, fontWeight: 500, marginTop: 4 }}>{p.label}</div>
                  <div style={{ fontFamily: T.fontNum, fontSize: 11, color: T.textSec, marginTop: 4, fontVariantNumeric: 'tabular-nums' }}>{p.miles.toFixed(1)} mi · {p.mins} min</div>
                </button>
            )}
            </div>
          </>
        }
      </div>

      {/* Schedule picker — slides up as a full-width bottom card over the search list */}
      {schedOpen &&
      <div style={{ position: 'absolute', top: -14, left: -22, right: -22, bottom: -24, zIndex: 20, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
          {/* Scrim */}
          <div onClick={() => setSchedOpen(false)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.55)', animation: 'mrt-fade-up .2s ease-out both' }} />
          {/* Card — full width, rounded top, flush to sheet bottom */}
          <div style={{ position: 'relative', borderRadius: '22px 22px 0 0', padding: '20px 22px 26px', background: '#16161a', borderTop: `0.5px solid ${T.border}`, boxShadow: '0 -10px 44px rgba(0,0,0,0.55)', animation: 'mrt-sched-up .3s cubic-bezier(.32,.72,0,1) both' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 }}>
              <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3 }}>Schedule pickup</div>
              <button onClick={() => setSchedOpen(false)} style={{ width: 26, height: 26, borderRadius: 13, background: T.elevated, border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <SFIcon name="xmark" size={10} color={T.textSec} weight={2} />
              </button>
            </div>

            <div style={{ fontSize: 10.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase', marginBottom: 9 }}>Day</div>
            <div className="mrt-noscroll" style={{ display: 'flex', gap: 7, overflowX: 'auto', marginBottom: 18, paddingBottom: 2 }}>
              {DAYS.map((d) =>
            <button key={d} onClick={() => setSchedDay(d)} style={{
              flexShrink: 0, padding: '9px 15px', borderRadius: 12, cursor: 'pointer',
              border: schedDay === d ? '0.5px solid transparent' : `0.5px solid ${T.border}`,
              background: schedDay === d ? T.gold : 'rgba(255,255,255,0.04)',
              color: schedDay === d ? '#1a1408' : T.textSec,
              fontFamily: T.font, fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1, whiteSpace: 'nowrap'
            }}>{d}</button>
            )}
            </div>

            <div style={{ fontSize: 10.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase', marginBottom: 9 }}>Time</div>
            <div className="mrt-noscroll" style={{ display: 'flex', gap: 7, overflowX: 'auto', marginBottom: 20, paddingBottom: 2 }}>
              {TIMES.map((t) =>
            <button key={t} onClick={() => setSchedTime(t)} style={{
              flexShrink: 0, padding: '9px 14px', borderRadius: 12, cursor: 'pointer',
              border: schedTime === t ? '0.5px solid transparent' : `0.5px solid ${T.border}`,
              background: schedTime === t ? T.gold : 'rgba(255,255,255,0.04)',
              color: schedTime === t ? '#1a1408' : T.textSec,
              fontFamily: T.fontNum, fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums'
            }}>{t}</button>
            )}
            </div>

            <Button variant="gold" onClick={confirmSchedule}>Set pickup · {schedDay} {schedTime}</Button>
          </div>
        </div>
      }
    </div>);

}
function ReviewContent({ dest, vehicleName, requesterName, fleet, fleetIdx, setFleetIdx, schedule, passenger, onBack, onConfirm }) {
  const S = useSurfaces();
  const [fleetOpen, setFleetOpen] = rrS(false);
  const sel = fleet && fleet[fleetIdx] || { owner: requesterName || 'Alex', name: vehicleName, battery: 68, etaMin: 6 };
  const tripMiles = (dest?.miles || 14).toFixed(1);
  const tripMins = dest?.mins || 28;
  const pickupMins = sel.etaMin || 6; // car → rider
  const fmtFromNow = (m) => {
    const d = new Date(Date.now() + m * 60000);
    let h = d.getHours();const mm = d.getMinutes();const ap = h >= 12 ? 'PM' : 'AM';h = h % 12 || 12;
    return `${h}:${String(mm).padStart(2, '0')} ${ap}`;
  };
  // Add minutes to a "5:30 PM" style string
  const addToClock = (clock, addMin) => {
    const mt = clock.match(/(\d+):(\d+)\s*(AM|PM)/i);
    if (!mt) return clock;
    let h = parseInt(mt[1], 10) % 12;if (/pm/i.test(mt[3])) h += 12;
    let total = h * 60 + parseInt(mt[2], 10) + addMin;
    total = (total % 1440 + 1440) % 1440;
    let hh = Math.floor(total / 60);const mm = total % 60;const ap = hh >= 12 ? 'PM' : 'AM';hh = hh % 12 || 12;
    return `${hh}:${String(mm).padStart(2, '0')} ${ap}`;
  };

  const pickupAt = schedule ? schedule.time : fmtFromNow(pickupMins);
  const arriveAt = schedule ? addToClock(schedule.time, tripMins) : fmtFromNow(pickupMins + tripMins);
  const pickupSub = schedule ? schedule.day : `${pickupMins} min away`;
  const stats = [
  { label: 'Pick-up', value: pickupAt, sub: pickupSub },
  { label: 'Arrive', value: arriveAt, sub: `${tripMins} min · ${tripMiles} mi trip` }];


  return (
    <div style={{ display: 'flex', flexDirection: 'column', position: 'relative' }}>
      {/* Back to edit the trip — natural top-left placement, opposite the close (X) */}
      <button onClick={onBack} style={{ display: 'inline-flex', alignSelf: 'flex-start', alignItems: 'center', gap: 3, padding: '2px 8px 2px 0', marginBottom: 10, background: 'transparent', border: 'none', cursor: 'pointer', color: T.gold, fontFamily: T.font, fontSize: 13, fontWeight: 600, letterSpacing: -0.1, WebkitTapHighlightColor: 'transparent' }}>
        <SFIcon name="chevron.left" size={13} color={T.gold} />
        <span>Change trip</span>
      </button>

      {/* Scheduled badge — only when a pickup time was set */}
      {schedule &&
      <div style={{ display: 'inline-flex', alignSelf: 'flex-start', alignItems: 'center', gap: 6, padding: '5px 11px', borderRadius: 999, background: 'rgba(201,168,76,0.12)', border: `0.5px solid ${T.gold}40`, marginBottom: 12 }}>
          <SFIcon name="calendar" size={12} color={T.gold} />
          <span style={{ fontSize: 11.5, fontWeight: 600, color: T.gold, letterSpacing: 0.1, whiteSpace: 'nowrap' }}>Scheduled · {schedule.day} {schedule.time}</span>
        </div>
      }

      {/* Destination */}
      <div style={{ marginBottom: 20, paddingRight: 40 }}>
        <div style={{ fontSize: 28, fontWeight: 600, color: T.text, letterSpacing: -0.7, lineHeight: 1.05, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{dest?.label || 'Pescadero'}</div>
        {dest?.sub && <div style={{ fontSize: 14.5, color: T.textSec, marginTop: 7, letterSpacing: -0.1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{dest.sub}</div>}
      </div>

      {/* Pick-up + arrival times */}
      <div style={{ display: 'flex', alignItems: 'stretch', marginBottom: 22 }}>
        {stats.map((s, i) =>
        <React.Fragment key={i}>
            {i === 1 && <div style={{ width: 1, background: T.border, margin: '2px 20px' }} />}
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 10.5, color: T.gold, fontWeight: 700, letterSpacing: 1.2, textTransform: 'uppercase', marginBottom: 9 }}>{s.label}</div>
              <div style={{ fontFamily: T.fontNum, fontSize: 27, fontWeight: 500, color: T.text, lineHeight: 1, letterSpacing: -0.6, fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>{s.value}</div>
              <div style={{ fontSize: 12.5, color: T.textSec, fontWeight: 400, marginTop: 8, letterSpacing: -0.1 }}>{s.sub}</div>
            </div>
          </React.Fragment>
        )}
      </div>

      {/* Passenger — who the ride is for + how they're notified */}
      {passenger?.name &&
      <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 13px', borderRadius: 13, marginBottom: 14, ...S.inner }}>
          <div style={{ width: 36, height: 36, borderRadius: 18, background: `radial-gradient(circle at 30% 30%, ${T.gold}, #8a6f28)`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13.5, fontWeight: 600, color: '#1a1408', flexShrink: 0, fontFamily: T.font }}>{passenger.name.trim().split(/\s+/).map((s) => s[0]).slice(0, 2).join('').toUpperCase()}</div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
              <span style={{ fontSize: 14.5, fontWeight: 600, color: T.text, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{passenger.name}</span>
              <span style={{ flexShrink: 0, fontSize: 9.5, fontWeight: 700, letterSpacing: 0.6, color: T.gold, background: `${T.gold}1f`, padding: '2px 7px', borderRadius: 99, textTransform: 'uppercase' }}>Passenger</span>
            </div>
            {passenger.phone ?
          <div style={{ fontSize: 12, color: T.textSec, marginTop: 2, fontFamily: T.fontNum }}>{passenger.phone}</div> :
          <div style={{ fontSize: 12, color: '#FF6B6B', marginTop: 2 }}>Add a mobile number to send the tracking link</div>}
          </div>
          {passenger.phone ?
        <button onClick={onBack} aria-label="Edit passenger" style={{ flexShrink: 0, display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 12, fontWeight: 600, color: T.gold, background: `${T.gold}18`, border: `0.5px solid ${T.gold}40`, padding: '6px 11px', borderRadius: 99, cursor: 'pointer', fontFamily: T.font, WebkitTapHighlightColor: 'transparent' }}>
              <SFIcon name="pencil" size={11} color={T.gold} />Edit
            </button> :
        <button onClick={onBack} style={{ flexShrink: 0, fontSize: 12, fontWeight: 600, color: T.gold, background: `${T.gold}18`, border: `0.5px solid ${T.gold}40`, padding: '6px 11px', borderRadius: 99, cursor: 'pointer', fontFamily: T.font, WebkitTapHighlightColor: 'transparent' }}>Add number</button>}
        </div>
      }

      {/* Vehicle — tap to pick from the shared fleet */}
      <button onClick={() => fleet && fleet.length > 1 && setFleetOpen(true)} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 13px', borderRadius: 13, marginBottom: 16, width: '100%', cursor: fleet && fleet.length > 1 ? 'pointer' : 'default', textAlign: 'left', background: 'transparent', border: `0.5px solid ${T.gold}24`, WebkitTapHighlightColor: 'transparent' }}>
        <div style={{ width: 36, height: 36, borderRadius: 18, background: `${T.gold}1f`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 600, color: T.gold, flexShrink: 0, fontFamily: T.font }}>{sel.owner[0]}</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 14.5, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>{sel.owner}’s {sel.name}</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 2 }}>
            <span style={{ width: 6, height: 6, borderRadius: 3, background: T.parked, boxShadow: `0 0 6px ${T.parked}99`, flexShrink: 0 }} />
            <span style={{ fontSize: 12, color: T.textSec, fontWeight: 400 }}>Available{schedule ? '' : ' now'} · {sel.battery}%</span>
          </div>
        </div>
        {fleet && fleet.length > 1 ?
        <div style={{ display: 'flex', alignItems: 'center', gap: 3, color: T.gold, fontSize: 12, fontWeight: 600, flexShrink: 0 }}><span>Change</span><SFIcon name="chevron.down" size={11} color={T.gold} /></div> :
        <SFIcon name="car.fill" size={15} color={T.textMuted} />}
      </button>

      {/* Primary action */}
      <Button variant="outline-draw" onClick={onConfirm}>
        <span className="mrt-gold-pulse">{schedule ? 'Schedule with' : 'Request from'} {sel.owner}</span>
      </Button>

      {/* Helper */}
      <div style={{ marginTop: 13, textAlign: 'center' }}>
        <span style={{ fontSize: 11.5, color: T.textMuted, letterSpacing: -0.1 }}>{passenger?.name && passenger.phone ?
          `${sel.owner} must accept — then we’ll text ${passenger.name.trim().split(/\s+/)[0]} the tracking link` :
          `${sel.owner} must accept before the ride is confirmed`}</span>
      </div>

      {/* Fleet picker — choose which shared Tesla */}
      {fleetOpen && fleet &&
      <div style={{ position: 'absolute', top: -14, left: -22, right: -22, bottom: -24, zIndex: 20, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
          <div onClick={() => setFleetOpen(false)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.55)', animation: 'mrt-fade-up .2s ease-out both' }} />
          <div style={{ position: 'relative', borderRadius: '22px 22px 0 0', padding: '20px 22px 26px', background: '#16161a', borderTop: `0.5px solid ${T.border}`, boxShadow: '0 -10px 44px rgba(0,0,0,0.55)', animation: 'mrt-sched-up .3s cubic-bezier(.32,.72,0,1) both' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14 }}>
              <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3 }}>Available rides</div>
              <button onClick={() => setFleetOpen(false)} style={{ width: 26, height: 26, borderRadius: 13, background: T.elevated, border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <SFIcon name="xmark" size={10} color={T.textSec} weight={2} />
              </button>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {fleet.map((f, i) => {
              const active = i === fleetIdx;
              return (
                <button key={f.id} onClick={() => {setFleetIdx(i);setFleetOpen(false);}} style={{
                  display: 'flex', alignItems: 'center', gap: 12, padding: '12px 13px', borderRadius: 14,
                  cursor: 'pointer', textAlign: 'left', width: '100%', WebkitTapHighlightColor: 'transparent',
                  background: active ? 'rgba(201,168,76,0.12)' : 'transparent',
                  border: `0.5px solid ${active ? T.gold + '66' : T.gold + '24'}`
                }}>
                    <div style={{ width: 38, height: 38, borderRadius: 19, background: `${T.gold}1f`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 15, fontWeight: 600, color: T.gold, flexShrink: 0, fontFamily: T.font }}>{f.owner[0]}</div>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontSize: 14.5, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>{f.owner}’s {f.name}</div>
                      <div style={{ fontSize: 12, color: T.textSec, marginTop: 2 }}>{f.rel} · {f.battery}% · {f.etaMin} min away</div>
                    </div>
                    {active ?
                  <SFIcon name="checkmark" size={15} color={T.gold} weight={2.2} /> :
                  <SFIcon name="chevron.right" size={13} color={T.textMuted} />}
                  </button>);

            })}
            </div>
          </div>
        </div>
      }
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Pending content
// ─────────────────────────────────────────────────────────────
function PendingContent({ dest, requesterName, passenger, sentAt, booked, pickup, vehicle, freeze, onCancel, onBooked }) {
  const [, force] = rrS(0);
  rrE(() => {const id = setInterval(() => force((n) => n + 1), 1000);return () => clearInterval(id);}, []);
  const elapsed = sentAt ? Math.max(0, Math.floor((Date.now() - sentAt) / 1000)) : 0;
  const ago = elapsed < 60 ? `${elapsed}s` : `${Math.floor(elapsed / 60)}m ${elapsed % 60}s`;
  const forSomeone = passenger?.name;
  const owner = requesterName || 'Alex';

  // Booking countdown — an Uber-style slide-fill that sweeps left→right until
  // the ride is booked, then hands off to the minimized map.
  const [secs, setSecs] = rrS(freeze ? 4 : 10);
  const [sent, setSent] = rrS(false);
  const doneRef = rrR(false);
  const sentRef = rrR(false);
  const finishSend = () => { if (!doneRef.current) { doneRef.current = true; onBooked && onBooked(); } };
  // Fill completes (or tap) → hold ~2s on a "Request sent" confirmation → hand off.
  const goSent = () => {
    if (sentRef.current) return; sentRef.current = true;
    setSent(true);
    setTimeout(finishSend, 1000);
  };
  rrE(() => {
    if (booked || freeze) return; // booked → quiet waiting card; freeze → docs hold the sending state
    const DUR = 10000, t0 = Date.now();
    const iv = setInterval(() => { setSecs(Math.max(1, Math.ceil((DUR - (Date.now() - t0)) / 1000))); }, 250);
    const to = setTimeout(goSent, DUR);
    return () => { clearInterval(iv); clearTimeout(to); };
  }, [booked, freeze]);

  const Beacon = (
    <div style={{ width: 64, height: 64, position: 'relative', marginBottom: 16 }}>
      <div style={{ position: 'absolute', inset: 0, borderRadius: 32, border: `2px solid ${T.gold}`, animation: 'mrt-ping 1.4s ease-out infinite', opacity: 0.4 }} />
      <div style={{ position: 'absolute', inset: 9, borderRadius: 23, border: `2px solid ${T.gold}`, animation: 'mrt-ping 1.4s ease-out infinite 0.4s', opacity: 0.5 }} />
      <div style={{ position: 'absolute', inset: 19, borderRadius: 14, background: T.gold, display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: `0 0 24px ${T.gold}99` }}>
        <SFIcon name="paperplane.fill" size={14} color="#1a1408" />
      </div>
    </div>
  );

  const ForChip = forSomeone ? (
    <div style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: '6px 12px', borderRadius: 99, background: 'rgba(201,168,76,0.12)', border: `0.5px solid ${T.gold}3a`, marginBottom: 18 }}>
      <SFIcon name="person.fill" size={11} color={T.gold} />
      <span style={{ fontSize: 12, color: T.text, fontWeight: 500 }}>For {passenger.name}</span>
    </div>
  ) : null;

  // Trip details — clearly-marked pickup → drop-off so the rider sees the
  // whole route, addresses and times while the ride is being booked.
  const fmtFromNow = (m) => { const d = new Date(Date.now() + m * 60000); let h = d.getHours();const mm = d.getMinutes();const ap = h >= 12 ? 'PM' : 'AM';h = h % 12 || 12; return `${h}:${String(mm).padStart(2, '0')} ${ap}`; };
  const pickupMins = vehicle?.etaMin || 6;
  const tripMins = dest?.mins || 28;
  const tripMiles = (dest?.miles || 14).toFixed(1);
  const pickupLabel = pickup?.label || 'Current location';
  const Itinerary = (
    <div style={{ width: '100%', border: `0.5px solid ${T.gold}24`, borderRadius: 14, padding: '12px 14px', marginBottom: 10, textAlign: 'left' }}>
      {/* Pickup */}
      <div style={{ display: 'flex', gap: 13 }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', flexShrink: 0 }}>
          <span style={{ width: 12, height: 12, borderRadius: 6, background: '#E7CD86', border: '2px solid #E7CD86', marginTop: 3 }} />
          <span style={{ flex: 1, width: 2, margin: '4px 0', minHeight: 24, background: `repeating-linear-gradient(${T.border} 0 3px, transparent 3px 6px)` }} />
        </div>
        <div style={{ flex: 1, minWidth: 0, paddingBottom: 12 }}>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12 }}>
            <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase', color: T.gold }}>Pickup</span>
            <span style={{ fontFamily: T.fontNum, fontSize: 13, fontWeight: 500, color: T.textSec, fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>{fmtFromNow(pickupMins)}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12, marginTop: 3 }}>
            <span style={{ fontSize: 15, fontWeight: 600, color: T.text, letterSpacing: -0.3, lineHeight: 1.25, textWrap: 'pretty', minWidth: 0 }}>{pickupLabel}</span>
            <span style={{ fontSize: 12, color: T.textMuted, flexShrink: 0, whiteSpace: 'nowrap' }}>{pickupMins} min away</span>
          </div>
        </div>
      </div>
      {/* Drop-off */}
      <div style={{ display: 'flex', gap: 13 }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', flexShrink: 0 }}>
          <span style={{ width: 12, height: 12, borderRadius: 3, background: 'transparent', border: `2px solid ${T.gold}`, marginTop: 3 }} />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12 }}>
            <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase', color: T.gold }}>Drop-off</span>
            <span style={{ fontFamily: T.fontNum, fontSize: 13, fontWeight: 500, color: T.textSec, fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>{fmtFromNow(pickupMins + tripMins)}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12, marginTop: 3 }}>
            <span style={{ fontSize: 15, fontWeight: 600, color: T.text, letterSpacing: -0.3, lineHeight: 1.25, textWrap: 'pretty', minWidth: 0 }}>{dest?.label || 'Destination'}</span>
            <span style={{ fontSize: 12, color: T.textMuted, flexShrink: 0, whiteSpace: 'nowrap' }}>{tripMiles} mi · {tripMins} min</span>
          </div>
          {dest?.sub && <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 3, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{dest.sub}</div>}
        </div>
      </div>
    </div>
  );

  // Shared vehicle — same "Your ride" + plate card used on the tracking sheet.
  const vColor = vehicle?.color || 'Mercury Silver';
  const vName = vehicle?.name || 'Cybercab';
  const vYearMake = (vehicle?.model || '2026 Tesla Cybercab').replace(new RegExp(`\\s*${vName}\\s*$`), '') || '2026 Tesla';
  const vPlate = vehicle?.plate || 'RBO-2046';
  const VehicleRow = vehicle ? (
    <div style={{ backgroundColor: 'transparent', border: `0.5px solid ${T.gold}24`, borderRadius: 14, padding: '11px 13px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginBottom: 14, textAlign: 'left' }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase', color: `${T.gold}99`, marginBottom: 5 }}>Your ride</div>
        <div style={{ fontSize: 15, fontWeight: 600, color: T.text, letterSpacing: -0.3, lineHeight: 1.2, textWrap: 'pretty' }}>{vColor} {vName}</div>
        <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{vYearMake}{forSomeone ? ` · for ${passenger.name}` : ''}</div>
      </div>
      <span style={{ flexShrink: 0, fontFamily: T.fontNum, fontSize: 14, fontWeight: 600, letterSpacing: 1, color: `${T.gold}cc`, padding: '5px 10px', borderRadius: 6, whiteSpace: 'nowrap', border: `0.5px solid ${T.gold}3a` }}>{vPlate}</span>
    </div>
  ) : null;

  // Reopened after booking → quiet "waiting" status (no re-running the countdown).
  if (booked) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', padding: '2px 0 0' }}>
        <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 4 }}>Request sent</div>
        <div style={{ fontSize: 13, color: T.textSec, lineHeight: 1.4, marginBottom: 13 }}>
          Waiting for <span style={{ color: T.text, fontWeight: 500 }}>{owner}</span> · sent {ago} ago
        </div>
        {ForChip}
        {Itinerary}
        {VehicleRow}
        {forSomeone && passenger.phone &&
        <div style={{ fontSize: 11.5, color: T.textMuted, lineHeight: 1.4, marginBottom: 12 }}>
          {passenger.name.trim().split(/\s+/)[0]} gets a tracking link the moment {owner} accepts.
        </div>}
        <button onClick={onCancel} style={{ alignSelf: 'center', background: 'transparent', border: 'none', color: '#FF6B6B', fontSize: 13, fontFamily: T.font, fontWeight: 500, cursor: 'pointer', padding: '10px 12px' }}>Cancel request</button>
      </div>);
  }

  // Booking in progress → slide-fill countdown.
  return (
    <div style={{ display: 'flex', flexDirection: 'column', padding: '2px 0 0' }}>
      <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 12 }}>
        Booking ride with <span style={{ color: T.gold }}>{owner}</span>
      </div>
      {ForChip}
      {Itinerary}
      {VehicleRow}
      {/* Sending CTA — gold border trace pulses, a gold fill slides left→right
          over 10s, then the button holds ~2s on "Request sent"; tap to send now. */}
      <button onClick={goSent}
        className="mrt-draw-btn"
        style={{ position: 'relative', width: '100%', height: 54, borderRadius: 14, overflow: 'hidden', background: 'rgba(201,168,76,0.06)', border: 'none', cursor: 'pointer', padding: 0, WebkitTapHighlightColor: 'transparent', marginBottom: 8 }}>
        {/* solid gold-brownish-black fill sliding left→right over 10s */}
        <div style={{ position: 'absolute', top: 0, left: 0, bottom: 0, width: '100%', zIndex: 0, background: '#3a2f12', transformOrigin: 'left center', transform: sent ? 'scaleX(1)' : freeze ? 'scaleX(0.6)' : undefined, animation: (sent || freeze) ? 'none' : 'mrt-send-fill 10s linear forwards' }} />
        {/* label */}
        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, fontSize: 15, fontWeight: 600, letterSpacing: -0.1, fontFamily: T.font, zIndex: 5 }}>
          {sent ? (<>
            <SFIcon name="checkmark" size={15} color={T.text} weight={2.4} />
            <span style={{ color: T.text }}>Request sent</span>
          </>) : (<>
            <span style={{ color: T.text }}>Sending request</span>
            <span style={{ fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums', color: T.text, opacity: 0.85 }}>{secs}s</span>
          </>)}
        </div>
      </button>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2 }}>
        <div style={{ fontSize: 11.5, color: T.textMuted, letterSpacing: -0.1 }}>Tap to send now</div>
        <button onClick={onCancel} style={{ background: 'transparent', border: 'none', color: '#FF6B6B', fontSize: 13, fontFamily: T.font, fontWeight: 500, cursor: 'pointer', padding: '8px 12px' }}>Cancel request</button>
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Outcome content (accepted or rejected)
// ─────────────────────────────────────────────────────────────
function OutcomeContent({ accepted, dest, requesterName, vehicleName, passenger, onTrack, onClose, onAgain }) {
  const forSomeone = passenger?.name;
  const firstName = forSomeone ? passenger.name.trim().split(/\s+/)[0] : '';
  if (accepted) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '4px 0 0' }} data-comment-anchor="aef036d70f-div-558-7">
        <div style={{
          width: 60, height: 60, borderRadius: 30, marginBottom: 14,
          background: `radial-gradient(circle at 30% 30%, ${T.driving} 0%, #1a8a3f 100%)`,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          boxShadow: `0 0 36px ${T.driving}44`
        }}>
          <SFIcon name="checkmark" size={26} color="#fff" weight={2} />
        </div>
        <div style={{ fontSize: 18, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6, textAlign: 'center' }}>{forSomeone ? `${firstName}’s ride is on the way` : "Your ride's on the way"}</div>
        <div style={{ fontSize: 12.5, color: T.textSec, textAlign: 'center', lineHeight: 1.45, marginBottom: forSomeone && passenger.phone ? 14 : 16, maxWidth: 280 }}>
          {requesterName || 'Alex'} sent the destination to <span style={{ color: T.text, fontWeight: 500 }}>{vehicleName}</span>.
        </div>
        {forSomeone && passenger.phone &&
        <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '9px 13px', borderRadius: 12, background: 'rgba(48,209,88,0.10)', border: '0.5px solid rgba(48,209,88,0.28)', marginBottom: 16, maxWidth: 300 }}>
            <SFIcon name="paperplane.fill" size={13} color={T.driving} />
            <span style={{ fontSize: 12, color: T.textSec, lineHeight: 1.35 }}>Tracking link texted to <span style={{ color: T.text, fontWeight: 600, fontFamily: T.fontNum }}>{passenger.phone}</span></span>
          </div>
        }
        <Button variant="gold" size="sm" onClick={onTrack || onClose}>{forSomeone ? 'Track ride' : 'Track ride'}</Button>
      </div>);

  }
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '4px 0 0' }}>
      <div style={{
        width: 60, height: 60, borderRadius: 30, marginBottom: 14,
        background: 'rgba(255,255,255,0.04)', border: `0.5px solid ${T.border}`,
        display: 'flex', alignItems: 'center', justifyContent: 'center'
      }}>
        <SFIcon name="xmark" size={22} color={T.textSec} />
      </div>
      <div style={{ fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6, textAlign: 'center' }}>Request declined</div>
      <div style={{ fontSize: 12.5, color: T.textSec, textAlign: 'center', lineHeight: 1.45, marginBottom: 16, maxWidth: 260 }}>
        {requesterName || 'Alex'} can't accept right now.
      </div>
      <div style={{ display: 'flex', gap: 8, width: '100%' }}>
        <Button variant="outline-muted" size="sm" onClick={onClose}>Close</Button>
        <Button variant="gold" size="sm" onClick={onAgain}>Try again</Button>
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Pin-drop content — compact sheet shown while choosing pickup on the map
// ─────────────────────────────────────────────────────────────
function PinDropContent({ pinAddress, onConfirm, onCancel }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 11, marginBottom: 12 }}>
        <span style={{ width: 36, height: 36, borderRadius: 18, background: 'rgba(201,168,76,0.16)', border: `0.5px solid ${T.gold}55`, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <SFIcon name="mappin" size={16} color={T.gold} />
        </span>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 10, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase' }}>Pickup location</div>
          <div style={{ fontSize: 16, color: T.text, fontWeight: 600, letterSpacing: -0.2, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{pinAddress}</div>
        </div>
      </div>
      <div style={{ fontSize: 12.5, color: T.textSec, marginBottom: 16, letterSpacing: -0.1 }}>Drag the map to move the pin, then confirm your pickup spot.</div>
      <Button variant="outline-draw" onClick={onConfirm}><span className="mrt-gold-pulse">Confirm pickup here</span></Button>
      <button onClick={onCancel} style={{ marginTop: 10, background: 'transparent', border: 'none', cursor: 'pointer', color: T.textSec, fontFamily: T.font, fontSize: 13, fontWeight: 500, padding: 4 }}>Cancel</button>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Tracking content — live, real-time view shown once a ride is accepted.
// Two legs: car drives to the pickup, then carries the rider to the
// destination. ETA + arrival clock update live from `progress` (0→1).
// ─────────────────────────────────────────────────────────────
function TrackingContent({ dest, requesterName, vehicleName, vehicle, pickup, passenger, progress = 0, onMinimize }) {
  const S = useSurfaces();
  // Mocked pickup point (rider hasn't dropped a custom pin in this flow).
  const pickupLabel = pickup?.label || 'Embarcadero Plaza';
  const tripMins = dest?.mins || 28;
  const pickupMins = 6; // car → rider
  const totalMins = pickupMins + tripMins;
  // First ~pickupMins worth of progress is the pickup leg.
  const pickupCut = pickupMins / totalMins;
  const atPickup = progress >= pickupCut;
  const remainMins = Math.max(0, Math.round((1 - progress) * totalMins));
  const toPickupMins = Math.max(0, Math.round((pickupCut - progress) / pickupCut * pickupMins));
  const arriving = remainMins <= 1;

  // Distance the car still has to cover — from pickup (pickup leg) or to
  // drop-off (in-ride leg).
  const pickupMilesTotal = 2.2;
  const pickupRemainMi = Math.max(0.1, (1 - Math.min(progress, pickupCut) / pickupCut) * pickupMilesTotal);
  const tripMiles = dest?.miles || 3.4;
  const rideProgress = Math.max(0, (progress - pickupCut) / (1 - pickupCut));
  const dropRemainMi = Math.max(0.1, (1 - rideProgress) * tripMiles);

  const clockFromNow = (m) => {
    const d = new Date(Date.now() + m * 60000);
    let h = d.getHours();const mm = d.getMinutes();const ap = h >= 12 ? 'PM' : 'AM';h = h % 12 || 12;
    return `${h}:${String(mm).padStart(2, '0')} ${ap}`;
  };
  const pickupClock = clockFromNow(Math.max(0, Math.round((pickupCut - Math.min(progress, pickupCut)) / pickupCut * pickupMins)));
  const arriveClock = clockFromNow(remainMins);

  // Three live stages: heading to pickup → in ride toward drop-off → arriving.
  const arrivingPickup = !atPickup && toPickupMins <= 1;
  const arrivingDropoff = atPickup && remainMins <= 2;
  const statusWord = !atPickup ?
    arrivingPickup ? 'Your ride is arriving' : 'Heading your way' :
    arrivingDropoff ? 'Arriving at drop-off' : `Heading to ${dest?.label || 'destination'}`;
  const etaClock = atPickup ? arriveClock : pickupClock;
  const carColor = vehicle?.color || 'Mercury Silver';
  const carName = vehicleName || vehicle?.name || 'Cybercab';
  const carYearMake = (vehicle?.model || '2026 Tesla Cybercab').replace(new RegExp(`\\s*${carName}\\s*$`), '') || '2026 Tesla';
  const carPlate = vehicle?.plate || 'RBO-2046';

  const headedLabel = atPickup ? (dest?.label || 'Destination') : pickupLabel;
  const headedEyebrow = atPickup ? 'Dropping you off at' : 'Picking you up at';

  // Consistent type scale used throughout the sheet:
  const eyebrow = { fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase' };

  const pickupDone = atPickup;
  const Stop = ({ dotColor, filled, label, place, clock, note, last }) => (
    <div style={{ display: 'flex', gap: 13 }}>
      {/* Timeline rail */}
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', flexShrink: 0 }}>
        <span style={{ width: 12, height: 12, borderRadius: label === 'Drop-off' ? 3 : 6, background: filled ? dotColor : T.bg, border: `2px solid ${dotColor}`, boxShadow: filled ? `0 0 8px ${dotColor}88` : 'none', marginTop: 3 }} />
        {!last && <span style={{ flex: 1, width: 2, margin: '4px 0', minHeight: 26, background: pickupDone ? T.gold : `repeating-linear-gradient(${T.border} 0 3px, transparent 3px 6px)` }} />}
      </div>
      {/* Stop content */}
      <div style={{ flex: 1, minWidth: 0, paddingBottom: last ? 0 : 16 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12 }}>
          <span style={{ ...eyebrow, fontSize: 10, color: T.gold }}>{label}</span>
          <span style={{ fontFamily: T.fontNum, fontSize: 13, fontWeight: 500, color: T.textSec, letterSpacing: -0.1, fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>{clock}</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12, marginTop: 3 }}>
          <span style={{ fontSize: 15, fontWeight: 600, color: T.text, letterSpacing: -0.3, lineHeight: 1.25, textWrap: 'pretty', minWidth: 0 }}>{place}</span>
          <span style={{ fontSize: 12, color: T.textMuted, flexShrink: 0, whiteSpace: 'nowrap' }}>{note}</span>
        </div>
      </div>
    </div>
  );

  // Plate chip — shimmering gold + large when the rider is still SPOTTING the
  // car (pickup phase); a quiet flat chip once they're aboard (in-ride/arrival).
  const PlateChip = ({ emphasize }) => emphasize ? (
    <span style={{ flexShrink: 0, position: 'relative', overflow: 'hidden', fontFamily: T.fontNum, fontSize: 18, fontWeight: 700, letterSpacing: 1.5, color: '#241B07', padding: '9px 14px', borderRadius: 8, whiteSpace: 'nowrap', border: `0.5px solid ${T.gold}`, backgroundColor: '#C9A84C', backgroundImage: 'linear-gradient(105deg, #B58E38 0%, #E9D08A 28%, #FFF4D6 46%, #E9D08A 64%, #B58E38 100%)', backgroundSize: '220% 100%', boxShadow: `0 1px 3px rgba(0,0,0,0.5), 0 0 14px ${T.gold}66`, animation: 'mrt-plate-shine 3.4s linear infinite' }}>{carPlate}</span>
  ) : (
    <span style={{ flexShrink: 0, fontFamily: T.fontNum, fontSize: 14, fontWeight: 600, letterSpacing: 1, color: `${T.gold}cc`, padding: '5px 10px', borderRadius: 6, whiteSpace: 'nowrap', border: `0.5px solid ${T.gold}3a` }}>{carPlate}</span>
  );

  // Vehicle + plate. Emphasized = the spotting card (pickup): gold-washed,
  // "Look for", big shimmering plate. Quiet = a reference row once aboard.
  const RideRow = ({ emphasize, style }) => (
    <div style={{ backgroundColor: emphasize ? `${T.gold}0f` : 'transparent', border: `0.5px solid ${emphasize ? T.gold + '66' : T.gold + '24'}`, borderRadius: S.innerRadius, padding: emphasize ? '13px 14px' : '11px 13px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, ...style }} data-comment-anchor="8e094dbc97-div-683-7">
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ ...eyebrow, fontSize: 9.5, color: emphasize ? T.gold : `${T.gold}99`, marginBottom: 5 }}>{emphasize ? 'Look for' : 'Your ride'}</div>
        <div style={{ fontSize: emphasize ? 17 : 15, fontWeight: 600, color: T.text, letterSpacing: -0.3, lineHeight: 1.2, textWrap: 'pretty' }}>{carColor} {carName}</div>
        <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{carYearMake}{passenger?.name ? ` · for ${passenger.name}` : ''}</div>
      </div>
      <PlateChip emphasize={emphasize} />
    </div>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      {arrivingDropoff ? (
        /* ARRIVAL — clean, readable header (no badge) */
        <div style={{ paddingBottom: 2 }} data-comment-anchor="73ae585dab-div-663-7">
          {/* Title + ETA on one line, destination + reminder stacked below */}
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 14 }}>
            <div style={{ fontSize: 24, fontWeight: 700, letterSpacing: -0.6, lineHeight: 1.1,
              background: `linear-gradient(105deg, ${T.gold} 0%, ${T.gold} 38%, #FFF4D6 50%, ${T.gold} 62%, ${T.gold} 100%)`,
              backgroundSize: '250% 100%', WebkitBackgroundClip: 'text', backgroundClip: 'text',
              WebkitTextFillColor: 'transparent', color: 'transparent',
              animation: 'mrt-text-shimmer 2.6s linear infinite' }}>Arriving</div>
            <div style={{ fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums', fontSize: 17, fontWeight: 600, color: T.text, letterSpacing: -0.3, whiteSpace: 'nowrap' }}>
              {remainMins < 1 ? '< 1 min' : `${remainMins} min`}<span style={{ color: T.textSec, fontWeight: 400, marginLeft: 8 }}>{dropRemainMi.toFixed(1)} mi</span>
            </div>
          </div>
          <div style={{ fontSize: 15, color: T.textSec, marginTop: 8, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            at <span style={{ color: T.text, fontWeight: 600 }}>{dest?.label || 'your destination'}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 14, paddingTop: 13, borderTop: `0.5px solid ${T.gold}24` }}>
            <SFIcon name="bag" size={13} color={T.gold} weight={1.8} />
            <span style={{ fontSize: 13.5, fontWeight: 500, color: `${T.gold}e6`, letterSpacing: -0.1 }}>Grab all your belongings</span>
          </div>
        </div>
      ) : (<>
        {/* Live status + hero ETA — the single dominant anchor of the card */}
        <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 14, marginBottom: 16 }} data-comment-anchor="73ae585dab-div-663-7">
          <div style={{ minWidth: 0, flex: 1 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginBottom: 8, minWidth: 0 }}>
              <PulseDot color={T.gold} />
              <span style={{ ...eyebrow, fontSize: 11, color: T.gold, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{statusWord}</span>
            </div>
            <div style={{ fontSize: 13.5, color: T.textSec, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
              {atPickup ? 'Dropping you off at ' : 'Picking you up at '}<span style={{ color: T.text, fontWeight: 600 }}>{atPickup ? (dest?.label || 'your destination') : pickupLabel}</span>
            </div>
          </div>
          <div style={{ textAlign: 'right', flexShrink: 0, fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums' }}>
            <div style={{ fontSize: 34, fontWeight: 700, color: T.text, letterSpacing: -1, lineHeight: 0.95 }}>
              {(atPickup ? remainMins : toPickupMins) < 1 ? '<1' : (atPickup ? remainMins : toPickupMins)}<span style={{ fontSize: 14, fontWeight: 600, color: `${T.gold}cc`, marginLeft: 4, letterSpacing: 0 }}>min</span>
            </div>
            <div style={{ fontSize: 12.5, color: `${T.gold}99`, marginTop: 5 }}>{(atPickup ? dropRemainMi : pickupRemainMi).toFixed(1)} mi away</div>
          </div>
        </div>

        {/* PICKUP: spot the car first (emphasized) → confirm the trip below.
           IN-RIDE: confirm the trip first → car is just a quiet reference. */}
        {!atPickup && <RideRow emphasize style={{ marginBottom: 12 }} />}

        {/* Itinerary — pickup → drop-off, for confirming the route */}
        <div style={{ backgroundColor: 'transparent', border: `0.5px solid ${T.gold}24`, borderRadius: S.innerRadius, padding: '15px 15px 15px', marginBottom: 12 }}>
          <Stop label="Pickup" dotColor="#E7CD86" filled={pickupDone}
            place={pickupLabel} clock={pickupClock}
            note={pickupDone ? 'Picked up' : `${pickupRemainMi.toFixed(1)} mi · ${toPickupMins} min`} />
          <Stop label="Drop-off" dotColor={T.gold} filled={false} last
            place={dest?.label || 'Destination'} clock={arriveClock}
            note={atPickup ? `${dropRemainMi.toFixed(1)} mi · ${remainMins} min` : `${tripMiles.toFixed(1)} mi trip`} />
        </div>

        {atPickup && <RideRow emphasize={false} />}
      </>)}

      {/* Arrival keeps a quiet ride reference (no spotting emphasis aboard) */}
      {arrivingDropoff && <RideRow emphasize={false} style={{ marginTop: 14 }} />}
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Ride summary — shown the moment the trip ends. Recaps the route, the
// vehicle, the FSD miles driven, and offers a tip (which, since no human
// ever touched the wheel, is gently played for laughs).
// ─────────────────────────────────────────────────────────────
function RideSummaryContent({ dest, vehicleName, vehicle, pickup, passenger, riderName, onDone }) {
  const S = useSurfaces();
  const [tip, setTip] = rrS(null);
  const route = rrM(() => buildSampleRoute(), []);
  const partOfDay = (() => { const h = new Date().getHours(); return h < 12 ? 'morning' : h < 18 ? 'afternoon' : 'evening'; })();
  const firstName = (riderName || (passenger && passenger.name) || 'Sam').trim().split(/\s+/)[0];
  const pickupLabel = pickup?.label || 'Embarcadero Plaza';
  const dropLabel = dest?.label || 'Destination';
  const tripMins = dest?.mins || 28;
  const pickupMins = 6;
  const tripMiles = dest?.miles || 3.4;
  const carColor = vehicle?.color || 'Mercury Silver';
  const carName = vehicleName || vehicle?.name || 'Cybercab';
  const carYearMake = (vehicle?.model || '2026 Tesla Cybercab').replace(new RegExp(`\\s*${carName}\\s*$`), '') || '2026 Tesla';
  const carPlate = vehicle?.plate || 'RBO-2046';
  // Every mile of a robotaxi trip is autonomous.
  const fsdMiles = tripMiles;

  const eyebrow = { fontSize: 9.5, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase' };

  // The joke: there is no driver to tip. Each option deadpans back.
  const tipQuips = {
    '$3': 'Your robotaxi beeped happily, then remembered it runs on electrons, not gratitude.',
    '$5': 'The steering wheel would thank you — if it had one.',
    '$8': '$8?! It’s blushing in binary: 01110100 01111000.',
    'Custom': 'There’s no driver back there. Just vibes and 4,000 TOPS of compute.',
  };
  const endedClock = (() => { const d = new Date(); let h = d.getHours(); const m = d.getMinutes(); const ap = h >= 12 ? 'PM' : 'AM'; h = h % 12 || 12; return `${h}:${String(m).padStart(2, '0')} ${ap}`; })();

  const stats = [
    { k: 'Trip', v: `${tripMins}`, u: 'min' },
    { k: 'FSD miles', v: fsdMiles.toFixed(1), u: 'mi', gold: true },
    { k: 'Autonomous', v: '100', u: '%' },
  ];

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: '100%' }}>
      {/* Greeting — warm, single-tone, unhurried */}
      <div style={{ ...eyebrow, fontSize: 10, color: `${T.gold}99`, marginBottom: 12 }}>Arrived · {endedClock}</div>
      <div style={{ fontSize: 25, fontWeight: 600, letterSpacing: -0.5, lineHeight: 1.25, textWrap: 'pretty', marginBottom: 24,
        background: `linear-gradient(105deg, ${T.gold} 0%, ${T.gold} 40%, #FFF4D6 50%, ${T.gold} 60%, ${T.gold} 100%)`,
        backgroundSize: '250% 100%', WebkitBackgroundClip: 'text', backgroundClip: 'text',
        WebkitTextFillColor: 'transparent', color: 'transparent', animation: 'mrt-text-shimmer 3.6s linear infinite' }}>
        Have a wonderful {partOfDay},<br />{firstName}.
      </div>

      {/* The journey — hero map, the moment to dwell on; destination rests on it */}
      <div style={{ position: 'relative', flex: 1, minHeight: 150, borderRadius: S.innerRadius, overflow: 'hidden', border: `0.5px solid ${T.gold}24` }}>
        <svg width="100%" height="100%" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
          <MapBackground width={402} height={600} seed={37} />
          <RouteLine path={route} progress={1} width={6} glow />
          <EndpointDot x={route[0][0]} y={route[0][1]} color={T.driving} size={14} />
          <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={16} />
        </svg>
        <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, padding: '44px 16px 15px', background: 'linear-gradient(180deg, rgba(8,8,8,0) 0%, rgba(8,8,8,0.82) 60%, rgba(8,8,8,0.94) 100%)' }}>
          <div style={{ ...eyebrow, fontSize: 9.5, color: `${T.gold}aa`, marginBottom: 5 }}>You arrived at</div>
          <div style={{ fontSize: 24, fontWeight: 700, color: T.gold, letterSpacing: -0.5, lineHeight: 1.05, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{dropLabel}</div>
          <div style={{ fontSize: 13, color: 'rgba(255,255,255,0.6)', marginTop: 4 }}>from {pickupLabel}</div>
        </div>
      </div>

      {/* Trip meta — a calm hairline strip, no competing boxes */}
      <div style={{ display: 'flex', alignItems: 'center', marginTop: 20, marginBottom: 18 }}>
        {stats.map((s, i) => (
          <React.Fragment key={s.k}>
            {i > 0 && <div style={{ width: 1, height: 30, background: `${T.gold}24`, margin: '0 18px' }} />}
            <div>
              <div style={{ fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums', fontSize: 21, fontWeight: 700, color: s.gold ? T.gold : T.text, letterSpacing: -0.5, lineHeight: 1 }}>
                {s.v}<span style={{ fontSize: 11, fontWeight: 600, color: s.gold ? `${T.gold}aa` : T.textMuted, marginLeft: 3 }}>{s.u}</span>
              </div>
              <div style={{ ...eyebrow, fontSize: 9.5, color: T.textMuted, marginTop: 6 }}>{s.k}</div>
            </div>
          </React.Fragment>
        ))}
      </div>

      {/* Vehicle — a quiet line, grounded by a single hairline */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, paddingTop: 16, borderTop: `0.5px solid ${T.gold}1f` }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ ...eyebrow, fontSize: 9.5, color: T.textMuted, marginBottom: 5 }}>You rode in</div>
          <div style={{ fontSize: 15, fontWeight: 600, color: T.text, letterSpacing: -0.3, lineHeight: 1.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{carColor} {carName}</div>
        </div>
        <span style={{ flexShrink: 0, fontFamily: T.fontNum, fontSize: 13.5, fontWeight: 600, letterSpacing: 1, color: `${T.gold}cc`, padding: '5px 10px', borderRadius: 6, whiteSpace: 'nowrap', border: `0.5px solid ${T.gold}3a` }}>{carPlate}</span>
      </div>

      {/* Tip — the joke. No driver to tip; tapping opens an elegant bottom sheet. */}
      <div style={{ marginTop: 22 }}>
        <div style={{ ...eyebrow, fontSize: 10, color: T.textMuted, marginBottom: 10 }}>Tip your driver</div>
        <div style={{ display: 'flex', gap: 8 }}>
          {['$3', '$5', '$8', 'Custom'].map((t) => {
            const on = tip === t;
            return (
              <button key={t} onClick={() => setTip(t)} style={{
                flex: 1, padding: '12px 6px', borderRadius: 12, cursor: 'pointer',
                background: on ? `${T.gold}1f` : 'transparent', border: `0.5px solid ${on ? T.gold + '88' : T.gold + '24'}`,
                color: on ? T.gold : T.text, fontFamily: T.font, fontSize: 14, fontWeight: 600, letterSpacing: -0.2,
                WebkitTapHighlightColor: 'transparent', transition: 'background .15s, border-color .15s'
              }}>{t}</button>
            );
          })}
        </div>
      </div>

      {/* Farewell action — shared animated outline-draw gold button */}
      <div style={{ marginTop: 22 }}>
        <Button variant="outline-draw" onClick={onDone}>See you soon</Button>
      </div>

      {/* Tip quip — an elegant dismissible bottom sheet, in the gold house style */}
      {tip && (
        <div style={{ position: 'absolute', inset: 0, zIndex: 40, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
          <div onClick={() => setTip(null)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.62)', animation: 'mrt-fade-up .2s ease-out both' }} />
          <div style={{ position: 'relative', borderRadius: '24px 24px 0 0', padding: '12px 24px 30px', background: '#100f0c', borderTop: `0.5px solid ${T.gold}3a`, boxShadow: '0 -18px 54px rgba(0,0,0,0.6)', animation: 'mrt-sched-up .34s cubic-bezier(.32,.72,0,1) both' }}>
            <div style={{ width: 36, height: 4, background: T.elevated, borderRadius: 4, margin: '0 auto 22px' }} />
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', textAlign: 'center' }}>
              <div style={{ width: 46, height: 46, borderRadius: 23, marginBottom: 16, display: 'flex', alignItems: 'center', justifyContent: 'center', background: `radial-gradient(circle at 30% 30%, ${T.gold}, #8A6F28)`, boxShadow: `0 0 22px ${T.gold}55` }}>
                <SFIcon name="face.smiling" size={22} color="#1a1408" weight={1.8} />
              </div>
              <div style={{ fontSize: 18, fontWeight: 700, color: T.gold, letterSpacing: -0.3, marginBottom: 8 }}>Haha, no need!</div>
              <div style={{ fontSize: 13.5, color: T.textSec, lineHeight: 1.5, maxWidth: 280, textWrap: 'pretty', marginBottom: 22 }}>{tipQuips[tip]}</div>
              <Button variant="outline-draw" onClick={() => setTip(null)}>Of course</Button>
            </div>
          </div>
        </div>
      )}
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Declined notice — compact bottom card shown over the search screen
// after a request is turned down. Dismiss (close) or Rebook (stay & retry).
// ─────────────────────────────────────────────────────────────
function DeclinedNotice({ requesterName = 'Alex', onDismiss, onRebook }) {
  return (
    <div style={{
      position: 'absolute', left: 14, right: 14, bottom: 14, zIndex: 40,
      borderRadius: 18, padding: '15px 16px',
      background: '#1a1a1c', border: `0.5px solid ${T.border}`,
      boxShadow: '0 -10px 44px rgba(0,0,0,0.55)',
      animation: 'mrt-sched-up .3s cubic-bezier(.32,.72,0,1) both'
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 13 }}>
        <div style={{ width: 36, height: 36, borderRadius: 18, background: 'rgba(255,59,48,0.14)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <SFIcon name="xmark" size={15} color="#FF6B6B" weight={2} />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 14.5, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>Ride declined</div>
          <div style={{ fontSize: 12, color: T.textSec, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{requesterName} can’t take this ride right now.</div>
        </div>
      </div>
      <div style={{ display: 'flex', gap: 9 }}>
        <Button variant="outline-muted" size="sm" onClick={onDismiss}>Dismiss</Button>
        <Button variant="gold" size="sm" onClick={onRebook}>Rebook</Button>
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// EXPANDING REQUEST SHEET — viewer-side overlay on the map
// ─────────────────────────────────────────────────────────────
function ExpandingRequestSheet({
  phase, setPhase,
  dest, setDest,
  vehicleName, requesterName, riderName,
  fleet, fleetIdx, setFleetIdx,
  schedule, setSchedule,
  rider, setRider, passenger, setPassenger,
  pickup, pinAddress, onMapConfirm, onMapCancel, onSchedule, setPinReturn,
  sentAt,
  driving, progress, trackProgress = 0, battery, speed,
  requestState, setRequestState, onAutoAccept,
  navHeight = 0,
  idleHeight,
  docFreeze = false, // docs-only: freeze the sending countdown (no auto-advance)
  children // 'idle' content (vehicle stats sheet) provided by parent
}) {
  // Pending elapsed timer
  const [elapsed, setElapsed] = rrS(0);
  const elapsedRef = rrR(0);
  // Has the booking countdown finished for the current pending request?
  const [booked, setBooked] = rrS(false);
  rrE(() => {
    if (phase !== 'pending') {elapsedRef.current = 0;setElapsed(0);return;}
    const id = setInterval(() => {elapsedRef.current += 1;setElapsed(elapsedRef.current);}, 1000);
    return () => clearInterval(id);
  }, [phase]);

  // React to ride state (owner accept/decline, or Tweaks-driven preview).
  // Lets the Tweaks 'State' control flip the live view from any phase
  // (but never interrupt an in-progress booking: search/review/pinDrop).
  rrE(() => {
    if (requestState !== 'pending') setBooked(false);
    const booking = phase === 'search' || phase === 'review' || phase === 'pinDrop';
    if (requestState === 'pending' && phase !== 'pending' && !booking) setPhase('pending');else
    if (requestState === 'accepted' && phase !== 'tracking') setPhase('tracking');else
    if (requestState === 'rejected' && phase !== 'search') setPhase('search');
  }, [requestState]);

  // After the request is sent and minimized to the map, simulate the owner
  // accepting: hold the "Request sent" banner briefly, then glide straight
  // into the to-pickup tracking sheet (no intermediate accepted banner).
  rrE(() => {
    if (docFreeze) return;
    if (!(booked && phase === 'idle' && requestState === 'pending')) return;
    const t = setTimeout(() => { setPhase('tracking'); (onAutoAccept || setRequestState)('accepted'); }, 2600);
    return () => clearTimeout(t);
  }, [booked, phase, requestState]);

  // Height by phase
  // Idle / search / pinDrop use fixed snap heights; committed action phases
  // (review, pending, tracking, accepted/rejected) size to their content so
  // every sheet ends with the same bottom padding — no dead space.
  // The ride summary takes over the whole screen — once the trip's done, the
  // map behind it is irrelevant and a full page feels like a destination.
  const isSummary = phase === 'tracking' && trackProgress >= 0.999;
  let h;
  if (phase === 'idle') h = idleHeight ?? SHEET_HEIGHTS.idleParked;else
  if (phase === 'search') h = SHEET_HEIGHTS.search;else
  if (phase === 'pinDrop') h = 'auto';else
  h = 'auto'; // review | pending | tracking | accepted | rejected
  if (isSummary) h = '100%';

  const closeToIdle = () => {setPhase('idle');setRequestState && setRequestState('idle');};
  const S = useSurfaces();
  // Passenger only applies when requesting for someone else.
  const pax = rider === 'other' ? passenger : null;

  // Drag the handle: down collapses search → idle, up expands idle → search
  const dragRef = rrR(null);
  const onHandleDown = (e) => {
    const startY = e.clientY ?? (e.touches && e.touches[0]?.clientY) ?? 0;
    dragRef.current = { startY, moved: 0 };
    const move = (ev) => {
      const y = ev.clientY ?? (ev.touches && ev.touches[0]?.clientY) ?? 0;
      dragRef.current.moved = y - dragRef.current.startY;
    };
    const up = () => {
      const d = dragRef.current ? dragRef.current.moved : 0;
      // Drag down: search dismisses; tracking/pending minimize to the map.
      if (d > 36 && phase === 'search') closeToIdle();else
      if (d > 36 && (phase === 'tracking' || phase === 'pending')) setPhase('idle');else
        // Drag up from the minimized map: reopen the active ride, or open search.
        if (d < -36 && phase === 'idle') {
          if (requestState === 'accepted') setPhase('tracking');else
          if (requestState === 'pending') setPhase('pending');else
          setPhase('search');
        }
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  };

  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0,
      height: h,
      zIndex: phase === 'idle' || phase === 'tracking' ? 30 : 60,
      borderTopLeftRadius: isSummary ? 0 : S.sheetRadius, borderTopRightRadius: isSummary ? 0 : S.sheetRadius,
      ...S.sheet,
      // Every request state — Idle, Pending, Accepted (tracking) and Declined —
      // shares one surface: a black card on the map with the same soft gold wash
      // from the top as the Sign In screen / brand mark.
      ...{
        backgroundColor: '#0A0A0A',
        backgroundImage: `radial-gradient(130% 62% at 50% -14%, rgba(201,168,76,0.14) 0%, rgba(10,10,10,0) 58%)`,
        backdropFilter: 'none', WebkitBackdropFilter: 'none',
        borderTopWidth: isSummary ? 0 : '0.5px',
        borderTopStyle: 'solid',
        borderTopColor: `${T.gold}2e`,
        boxShadow: '0 -16px 40px rgba(0,0,0,0.5)',
        borderTopLeftRadius: isSummary ? 0 : S.sheetRadius, borderTopRightRadius: isSummary ? 0 : S.sheetRadius,
      },
      transition: 'height .42s cubic-bezier(.32,.72,0,1)',
      display: 'flex', flexDirection: 'column',
      overflow: 'hidden'
    }} data-comment-anchor="d3b26ebb52-div-777-5">
      {/* Drag handle — only on the interactive sheet phases, not the static idle / tracking pages */}
      {phase !== 'idle' && phase !== 'tracking' && (
      <div onPointerDown={onHandleDown} style={{
        padding: '8px 0 6px', margin: '0 auto', flexShrink: 0,
        cursor: 'grab', touchAction: 'none', width: '60%',
        display: 'flex', justifyContent: 'center'
      }}>
        <div style={{ width: 36, height: 4, background: T.elevated, borderRadius: 4 }} />
      </div>
      )}

      {/* Close (X) — pending/outcome only; tracking minimizes via drag, not an X */}
      {phase !== 'idle' && phase !== 'search' && phase !== 'pinDrop' && phase !== 'tracking' &&
      <button onClick={() => {if (phase === 'pending') setPhase('idle');else closeToIdle();}} style={{
        position: 'absolute', top: 14, right: 14, zIndex: 5,
        width: 28, height: 28, borderRadius: 14,
        background: T.elevated, border: 'none', cursor: 'pointer',
        display: 'flex', alignItems: 'center', justifyContent: 'center'
      }}>
          <SFIcon name="xmark" size={11} color={T.textSec} weight={2} />
        </button>
      }

      {/* Phase content */}
      <div key={phase} style={{
        flex: 1, padding: isSummary ? '76px 22px 30px' : phase === 'idle' ? '14px 22px 98px' : phase === 'search' ? '14px 22px 100px' : phase === 'tracking' ? '14px 22px 100px' : phase === 'pinDrop' ? '14px 22px 16px' : '14px 22px 30px', minHeight: 0,
        display: 'flex', flexDirection: 'column',
        animation: phase === 'tracking' ? 'mrt-track-in .6s cubic-bezier(.32,.72,0,1) .08s both' : undefined
      }} data-comment-anchor="3d29aa7516-div-720-7">
        {phase === 'idle' && children}
        {phase === 'search' &&
        <SearchContent vehicleName={vehicleName} requesterName={requesterName}
        schedule={schedule} setSchedule={setSchedule}
        rider={rider} setRider={setRider} passenger={passenger} setPassenger={setPassenger}
        pickup={pickup} onPickOnMap={() => { setPinReturn && setPinReturn('search'); setPhase('pinDrop'); }}
        onSelect={(d) => { setDest(d); if (pickup) { setPhase('review'); } else { setPinReturn && setPinReturn('review'); setPhase('pinDrop'); } }} />
        }
        {phase === 'pinDrop' &&
        <PinDropContent pinAddress={pinAddress}
        onConfirm={onMapConfirm} onCancel={onMapCancel} />
        }
        {phase === 'review' &&
        <ReviewContent dest={dest} vehicleName={vehicleName} requesterName={requesterName}
        fleet={fleet} fleetIdx={fleetIdx} setFleetIdx={setFleetIdx} schedule={schedule} passenger={pax}
        onBack={() => setPhase('search')}
        onConfirm={() => {
          if (schedule) {onSchedule && onSchedule();} else
          {setPhase('pending');setRequestState && setRequestState('pending');}
        }} />
        }
        {phase === 'pending' &&
        <PendingContent dest={dest} requesterName={requesterName} passenger={pax} sentAt={sentAt}
        pickup={pickup} vehicle={fleet && fleet[fleetIdx]} freeze={docFreeze}
        booked={booked} onBooked={() => { setBooked(true); setPhase('idle'); }}
        onCancel={closeToIdle} />
        }
        {phase === 'tracking' && (trackProgress >= 0.999 ?
        <RideSummaryContent dest={dest} vehicleName={vehicleName} vehicle={fleet && fleet[fleetIdx]} pickup={pickup} passenger={pax} riderName={riderName} onDone={closeToIdle} /> :
        <TrackingContent dest={dest} requesterName={requesterName} vehicleName={vehicleName} vehicle={fleet && fleet[fleetIdx]} pickup={pickup} passenger={pax}
        progress={trackProgress} onMinimize={() => setPhase('idle')} />)
        }
      </div>

      {/* Declined — a light bottom card over the search screen so the rider can
           dismiss or rebook without a full-screen dead-end. */}
      {requestState === 'rejected' && phase === 'search' &&
      <DeclinedNotice requesterName={requesterName}
      onDismiss={closeToIdle}
      onRebook={() => {setRequestState && setRequestState('idle');setPhase('search');}} />
      }
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Owner side — incoming ride request modal sheet
// ─────────────────────────────────────────────────────────────
function IncomingRequestSheet({ visible, requesterName = 'Alex', dest, vehicleName = 'Cybercab', battery = 68, kind = 'now', schedule = null, passenger = null, onAccept, onReject }) {
  const S = useSurfaces();
  const [sending, setSending] = rrS(false);
  const [sent, setSent] = rrS(false);
  const route = rrM(() => buildSampleRoute(), []);
  const scheduled = kind === 'scheduled' && schedule;
  const forSomeone = passenger?.name;

  rrE(() => {if (!visible) {setSending(false);setSent(false);}}, [visible]);

  const handleAccept = () => {
    setSending(true);
    setTimeout(() => setSent(true), 700);
    setTimeout(() => onAccept && onAccept(), 1700);
  };

  return (
    <div style={{
      position: 'absolute', inset: 0, zIndex: 60,
      pointerEvents: visible ? 'auto' : 'none',
      background: visible ? 'rgba(0,0,0,0.5)' : 'rgba(0,0,0,0)',
      backdropFilter: visible ? 'blur(8px)' : 'blur(0px)',
      WebkitBackdropFilter: visible ? 'blur(8px)' : 'blur(0px)',
      transition: 'background .3s, backdrop-filter .3s',
      display: 'flex', flexDirection: 'column', justifyContent: 'flex-end'
    }}>
      <div style={{
        borderTopLeftRadius: S.modalRadius, borderTopRightRadius: S.modalRadius,
        padding: '14px 24px 32px',
        transform: visible ? 'translateY(0)' : 'translateY(110%)',
        transition: 'transform .42s cubic-bezier(.32,.72,0,1)',
        ...S.modalSheet
      }}>
        <div style={{ width: 36, height: 4, background: T.elevated, borderRadius: 4, margin: '0 auto 16px' }} />
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 18 }}>
          <span style={{ width: 7, height: 7, borderRadius: 4, background: T.gold, boxShadow: `0 0 8px ${T.gold}`, animation: 'mrt-glow-breathe 1.6s ease-in-out infinite' }} />
          <span style={{ fontSize: 10, color: T.gold, letterSpacing: 1.2, fontWeight: 700, textTransform: 'uppercase' }}>{scheduled ? 'Scheduled ride request' : 'Incoming ride request'}</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 18 }}>
          <div style={{
            width: 48, height: 48, borderRadius: 24,
            background: 'linear-gradient(135deg, #6d8eff 0%, #9D7CFF 100%)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontFamily: T.font, fontSize: 17, fontWeight: 600, color: '#fff', flexShrink: 0
          }}>{requesterName.slice(0, 1)}</div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 16, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>{forSomeone ? `${requesterName} requested a ride` : `${requesterName} wants a ride`}</div>
            <div style={{ fontSize: 12, color: T.textSec, marginTop: 2 }}>{scheduled ? `Scheduled · ${schedule.day} ${schedule.time}` : 'Shared viewer · just now'}</div>
          </div>
        </div>
        {forSomeone &&
        <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '10px 13px', borderRadius: 13, background: 'rgba(201,168,76,0.08)', border: `0.5px solid ${T.gold}33`, marginBottom: 16 }}>
            <div style={{ width: 34, height: 34, borderRadius: 17, background: `radial-gradient(circle at 30% 30%, ${T.gold}, #8a6f28)`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12.5, fontWeight: 600, color: '#1a1408', flexShrink: 0, fontFamily: T.font }}>{passenger.name.trim().split(/\s+/).map((s) => s[0]).slice(0, 2).join('').toUpperCase()}</div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                <span style={{ fontSize: 14, fontWeight: 600, color: T.text, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{passenger.name}</span>
                <span style={{ flexShrink: 0, fontSize: 9, fontWeight: 700, letterSpacing: 0.6, color: T.gold, background: `${T.gold}1f`, padding: '2px 6px', borderRadius: 99, textTransform: 'uppercase' }}>Passenger</span>
              </div>
              {passenger.phone && <div style={{ fontSize: 11.5, color: T.textSec, marginTop: 2, fontFamily: T.fontNum }}>{passenger.phone}</div>}
            </div>
            <SFIcon name="person.fill" size={15} color={T.textMuted} />
          </div>
        }
        <div style={{ background: T.surface, borderRadius: 16, overflow: 'hidden', border: `0.5px solid ${T.border}`, marginBottom: 14 }}>
          <div style={{ position: 'relative', height: 116, overflow: 'hidden' }}>
            <MapBackground width={402} height={116} seed={42} />
            <svg width="402" height="116" viewBox="0 0 402 600" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
              <RouteLine path={route} progress={1} width={5} glow />
              <EndpointDot x={route[0][0]} y={route[0][1]} color={T.driving} size={11} />
              <EndpointDot x={route[route.length - 1][0]} y={route[route.length - 1][1]} color={T.gold} size={13} />
            </svg>
            <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(180deg, transparent 30%, rgba(21,21,24,0.92) 100%)' }} />
            <div style={{ position: 'absolute', bottom: 10, left: 14, right: 14, display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ width: 7, height: 7, borderRadius: 4, background: T.gold, boxShadow: `0 0 6px ${T.gold}` }} />
              <span style={{ fontSize: 16, fontWeight: 600, color: T.text, letterSpacing: -0.3, flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{dest?.label || 'Pescadero'}</span>
            </div>
          </div>
          <div style={{ padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 16, fontFamily: T.fontNum, fontVariantNumeric: 'tabular-nums' }}>
            <div>
              <div style={{ fontSize: 9, color: T.textMuted, letterSpacing: 0.8, fontWeight: 600, textTransform: 'uppercase' }}>Distance</div>
              <div style={{ fontSize: 14, color: T.text, fontWeight: 500, marginTop: 2 }}>{(dest?.miles || 14).toFixed(1)} mi</div>
            </div>
            <div style={{ width: 1, height: 22, background: T.border }} />
            <div>
              <div style={{ fontSize: 9, color: T.textMuted, letterSpacing: 0.8, fontWeight: 600, textTransform: 'uppercase' }}>Drive time</div>
              <div style={{ fontSize: 14, color: T.text, fontWeight: 500, marginTop: 2 }}>~{dest?.mins || 28} min</div>
            </div>
            <div style={{ width: 1, height: 22, background: T.border }} />
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 9, color: T.textMuted, letterSpacing: 0.8, fontWeight: 600, textTransform: 'uppercase' }}>Battery after</div>
              <div style={{ fontSize: 14, color: T.text, fontWeight: 500, marginTop: 2 }}>{Math.max(10, battery - Math.round((dest?.miles || 14) * 0.7))}%</div>
            </div>
          </div>
        </div>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8, padding: '8px 12px',
          background: scheduled ? 'rgba(201,168,76,0.08)' : 'rgba(48,209,88,0.06)', border: `0.5px solid ${scheduled ? 'rgba(201,168,76,0.25)' : 'rgba(48,209,88,0.20)'}`,
          borderRadius: 10, marginBottom: 18, fontSize: 12
        }}>
          {scheduled ?
          <>
              <SFIcon name="calendar" size={13} color={T.gold} />
              <span style={{ color: T.text, fontWeight: 500 }}>{vehicleName}</span>
              <span style={{ color: T.textSec }}>reserved for {schedule.day} {schedule.time}</span>
            </> :

          <>
              <span style={{ width: 6, height: 6, borderRadius: 3, background: T.parked }} />
              <span style={{ color: T.text, fontWeight: 500 }}>{vehicleName}</span>
              <span style={{ color: T.textSec }}>is parked · ready to dispatch</span>
            </>
          }
        </div>
        {sent ?
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10,
          height: 50, borderRadius: T.radiusInput,
          background: 'rgba(48,209,88,0.14)', border: '0.5px solid rgba(48,209,88,0.35)',
          color: T.driving, fontFamily: T.font, fontSize: 15, fontWeight: 600,
          animation: 'mrt-fade-up .35s ease-out both'
        }}>
            <SFIcon name="checkmark" size={16} color={T.driving} weight={2} />
            {scheduled ? `Reserved for ${schedule.day} ${schedule.time}` : `Destination sent to ${vehicleName}`}
          </div> :
        sending ?
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10,
          height: 50, borderRadius: T.radiusInput, background: T.gold, color: '#1a1408',
          fontFamily: T.font, fontSize: 15, fontWeight: 600
        }}>
            <span style={{
            width: 14, height: 14, borderRadius: 7,
            border: '2px solid #1a1408', borderTopColor: 'transparent',
            animation: 'mrt-spin 0.8s linear infinite'
          }} />
            {scheduled ? 'Confirming…' : `Sending to ${vehicleName}…`}
          </div> :

        <div style={{ display: 'flex', gap: 10 }}>
            <Button variant="outline-muted" onClick={onReject} style={{ backgroundColor: 'rgba(255,59,48,0.13)', backgroundImage: 'none', color: '#FF6B6B', border: '1px solid rgba(255,59,48,0.42)', boxShadow: 'none' }}>Decline</Button>
            <Button variant="outline-draw" onClick={handleAccept}><span className="mrt-gold-pulse">{scheduled ? 'Accept ride' : 'Accept & send'}</span></Button>
          </div>
        }
        {!sending && !sent &&
        <div style={{ fontSize: 11, color: T.textMuted, textAlign: 'center', marginTop: 12, letterSpacing: 0.2 }}>
            {forSomeone && passenger.phone ?
          `Accepting texts ${passenger.name.trim().split(/\s+/)[0]} a live tracking link${scheduled ? '' : ` and routes ${vehicleName}`}.` :
          scheduled ?
          `${vehicleName} will be reserved for ${schedule.day} ${schedule.time}.` :
          `Accepting will route ${vehicleName} to ${dest?.label || 'this destination'}.`}
          </div>
        }
      </div>
    </div>);

}

// ─────────────────────────────────────────────────────────────
// Owner toast (top of screen) after accept
// ─────────────────────────────────────────────────────────────
function RouteSentToast({ visible, vehicleName, dest, kind = 'now', schedule = null, rider = 'Sam', passenger = null }) {
  const S = useSurfaces();
  const scheduled = kind === 'scheduled' && schedule;
  const forSomeone = passenger?.name;
  return (
    <div style={{
      position: 'absolute', top: 56, left: 14, right: 14, zIndex: 55,
      transform: visible ? 'translateY(0)' : 'translateY(-140%)',
      opacity: visible ? 1 : 0,
      transition: 'transform .42s cubic-bezier(.32,.72,0,1), opacity .3s',
      pointerEvents: visible ? 'auto' : 'none'
    }}>
      <div style={{
        borderRadius: 20, padding: '12px 16px',
        display: 'flex', alignItems: 'center', gap: 12,
        ...S.banner, border: `0.5px solid ${T.gold}44`
      }}>
        <div style={{ width: 30, height: 30, borderRadius: 15, background: 'rgba(201,168,76,0.18)', display: 'flex', alignItems: 'center', justifyContent: 'center', border: `0.5px solid ${T.gold}55` }}>
          <SFIcon name={scheduled ? 'calendar' : 'paperplane.fill'} size={13} color={T.gold} />
        </div>
        <div style={{ flex: 1, lineHeight: 1.2 }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: T.text, letterSpacing: -0.1 }}>{scheduled ? `Ride scheduled · ${schedule.day} ${schedule.time}` : `Destination sent to ${vehicleName}`}</div>
          <div style={{ fontSize: 11, color: T.textSec, marginTop: 2 }}>{forSomeone ? `${passenger.name} got a tracking link · ${dest?.label || 'Pescadero'}` : scheduled ? `${rider} · ${dest?.label || 'SFO'} · ${vehicleName} reserved` : `Heading to ${dest?.label || 'Pescadero'} · ${dest?.mins || 28} min`}</div>
        </div>
      </div>
    </div>);

}

(function injectKeyframes() {
  if (document.getElementById('mrt-rr-keyframes')) return;
  const s = document.createElement('style');s.id = 'mrt-rr-keyframes';
  s.textContent = `
    @keyframes mrt-spin { to { transform: rotate(360deg); } }
    @keyframes mrt-ping {
      0%   { transform: scale(0.9); opacity: 0.7; }
      80%, 100% { transform: scale(1.6); opacity: 0; }
    }
    @keyframes mrt-arrive-pop {
      0%   { transform: scale(0.4); opacity: 0; }
      55%  { transform: scale(1.12); opacity: 1; }
      75%  { transform: scale(0.96); }
      100% { transform: scale(1); opacity: 1; }
    }
    @keyframes mrt-arrive-bob {
      0%, 100% { transform: translateY(0); }
      50%      { transform: translateY(-5px); }
    }
    @keyframes mrt-arrive-rise {
      from { opacity: 0; transform: translateY(10px); }
      to   { opacity: 1; transform: translateY(0); }
    }
    @keyframes mrt-gold-breathe {
      0%, 100% { opacity: 0.4; transform: scale(0.94); }
      50%      { opacity: 0.95; transform: scale(1.06); }
    }
    @keyframes mrt-plate-shine {
      0%   { background-position: 140% 0; }
      100% { background-position: -40% 0; }
    }
    @keyframes mrt-send-fill {
      from { transform: scaleX(0); }
      to   { transform: scaleX(1); }
    }
    @keyframes mrt-track-in {
      0%   { opacity: 0; transform: translateY(14px) scale(0.985); }
      100% { opacity: 1; transform: translateY(0) scale(1); }
    }
    @keyframes mrt-text-shimmer {
      0%   { background-position: 180% 0; }
      100% { background-position: -80% 0; }
    }
  `;
  document.head.appendChild(s);
})();

Object.assign(window, {
  ExpandingRequestSheet, IncomingRequestSheet, RouteSentToast,
  SAVED_PLACES, RECENT_PLACES, SHEET_HEIGHTS
});