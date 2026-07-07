// Owner vehicle controls — the rich, interactive surface that lives in the
// expanded map bottom sheet. Climate, media, status, tire pressure, FSD,
// odometer, and full vehicle details (incl. VIN). Everything here is live.

const { useState: vcS, useRef: vcR } = React;

// Styled range slider with a gold fill up to the thumb.
function Slider({ value, min, max, step = 1, onChange, color = T.gold, height = 6 }) {
  const pct = ((value - min) / (max - min)) * 100;
  return (
    <input
      type="range" className="mrt-range"
      min={min} max={max} step={step} value={value}
      onChange={(e) => onChange(parseFloat(e.target.value))}
      style={{
        height,
        background: `linear-gradient(90deg, ${color} 0%, ${color} ${pct}%, ${T.elevated} ${pct}%, ${T.elevated} 100%)`,
      }}
    />
  );
}

// Big square quick-control tile (Lock, Climate, Frunk, Charge…)
function ControlTile({ icon, label, sub, active, activeColor = T.gold, onClick }) {
  return (
    <button onClick={onClick} style={{
      flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 8,
      padding: '13px 13px 12px', borderRadius: 16, cursor: 'pointer', textAlign: 'left',
      border: `0.5px solid ${active ? activeColor + '66' : T.border}`,
      background: active ? `${activeColor}1f` : 'rgba(255,255,255,0.035)',
      transition: 'background .18s, border-color .18s',
      WebkitTapHighlightColor: 'transparent',
    }}>
      <SFIcon name={icon} size={20} color={active ? activeColor : T.textSec}/>
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: T.text, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{label}</div>
        <div style={{ fontSize: 11, color: active ? activeColor : T.textMuted, fontWeight: 500, marginTop: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{sub}</div>
      </div>
    </button>
  );
}

function SectionCard({ title, right, children }) {
  const S = useSurfaces();
  return (
    <div style={{ marginTop: 18 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 10 }}>
        <Label>{title}</Label>
        {right}
      </div>
      <div style={{ borderRadius: 18, padding: 16, ...S.inner }}>{children}</div>
    </div>
  );
}

// Seat-climate level stepper — 3 segments tinted by mode (warm for heat,
// cool blue for ventilation).
function HeatLevel({ value, onChange, color = T.charging }) {
  return (
    <div style={{ display: 'flex', gap: 4 }}>
      {[1, 2, 3].map(n => (
        <button key={n} onClick={() => onChange(value === n ? 0 : n)} style={{
          width: 22, height: 22, borderRadius: 6, border: 'none', cursor: 'pointer', padding: 0,
          background: value >= n ? color : 'rgba(255,255,255,0.07)',
          transition: 'background .15s', WebkitTapHighlightColor: 'transparent',
        }}/>
      ))}
    </div>
  );
}

// Cool/ventilation accent (iOS system blue).
const SEAT_COOL = '#5AC8FA';

// One seat's climate control. Heating always; a Heat/Cool switch appears only
// when the vehicle supports ventilated seats. Switching modes resets the level.
function SeatRow({ label, vent, mode, setMode, level, setLevel }) {
  const active = level > 0;
  const accent = mode === 'cool' ? SEAT_COOL : T.charging;
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 13 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <SFIcon name={mode === 'cool' ? 'snowflake' : 'sun.max.fill'} size={14} color={active ? accent : T.textMuted}/>
        <span style={{ fontSize: 12.5, color: T.textSec, fontWeight: 500 }}>{label}</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        {vent && (
          <div style={{ display: 'flex', gap: 3, padding: 3, borderRadius: 9, background: 'rgba(255,255,255,0.05)' }}>
            {[['heat', 'Heat', T.charging], ['cool', 'Cool', SEAT_COOL]].map(([k, lab, c]) => (
              <button key={k} onClick={() => { setMode(k); setLevel(0); }} style={{
                padding: '4px 9px', borderRadius: 6, border: 'none', cursor: 'pointer',
                fontFamily: T.font, fontSize: 11, fontWeight: 600,
                background: mode === k ? c : 'transparent', color: mode === k ? '#1a1408' : T.textSec,
                transition: 'background .15s, color .15s', WebkitTapHighlightColor: 'transparent',
              }}>{lab}</button>
            ))}
          </div>
        )}
        <HeatLevel value={level} onChange={setLevel} color={accent}/>
      </div>
    </div>
  );
}

// Tesla-style fan-speed bar — 10 ascending segments, tap to set the level.
function FanBar({ value, onChange }) {
  return (
    <div style={{ display: 'flex', gap: 3, alignItems: 'flex-end', height: 26 }}>
      {Array.from({ length: 10 }, (_, i) => {
        const n = i + 1;
        const on = value >= n;
        return (
          <button key={n} onClick={() => onChange(value === n ? n - 1 : n)} style={{
            flex: 1, height: `${42 + i * 6.4}%`, borderRadius: 3, border: 'none', cursor: 'pointer', padding: 0,
            background: on ? T.gold : 'rgba(255,255,255,0.07)',
            transition: 'background .14s', WebkitTapHighlightColor: 'transparent',
          }}/>
        );
      })}
    </div>
  );
}

// Editable license plate — Tesla's data doesn't include the plate, so the
// owner sets it manually. The row opens a full edit sheet.
function PlateRow({ value, onEdit }) {
  return (
    <button onClick={onEdit} style={{
      all: 'unset', boxSizing: 'border-box', display: 'flex', width: '100%',
      justifyContent: 'space-between', alignItems: 'center', padding: '8px 0',
      cursor: 'pointer', fontFamily: T.font, WebkitTapHighlightColor: 'transparent',
    }}>
      <span style={{ fontSize: 13, color: T.textSec }}>Plate</span>
      <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontFamily: T.fontNum, fontSize: 13, fontWeight: 600, color: value ? T.text : T.textMuted, letterSpacing: 0.6, fontVariantNumeric: 'tabular-nums' }}>{value || 'Add plate'}</span>
        <span style={{ display: 'flex', width: 24, height: 24, borderRadius: 12, background: 'rgba(255,255,255,0.06)', alignItems: 'center', justifyContent: 'center' }}>
          <SFIcon name="pencil" size={12} color={T.gold}/>
        </span>
      </span>
    </button>
  );
}

// Full plate-edit flow — slides up over the whole phone screen (portaled out
// of the controls sheet), validates, and commits on Save.
function PlateEditModal({ initial, onCancel, onSave }) {
  const S = useSurfaces();
  const [val, setVal] = vcS(initial || '');
  const inputRef = vcR(null);
  React.useEffect(() => {
    const t = setTimeout(() => { if (inputRef.current) { inputRef.current.focus(); inputRef.current.select(); } }, 80);
    return () => clearTimeout(t);
  }, []);
  const clean = val.trim();
  const valid = clean.length >= 2;
  const changed = clean !== (initial || '').trim();
  const target = typeof document !== 'undefined' ? document.getElementById('mrt-screen') : null;
  if (!target) return null;
  const modal = (
    <div style={{ position: 'absolute', inset: 0, zIndex: 90, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', fontFamily: T.font }}>
      <div onClick={onCancel} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.58)', animation: 'mrt-fade-up .22s ease-out both' }}/>
      <div style={{
        position: 'relative',
        borderTopLeftRadius: S.modalRadius, borderTopRightRadius: S.modalRadius,
        padding: '14px 24px 30px',
        animation: 'mrt-sched-up .34s cubic-bezier(.32,.72,0,1) both',
        ...S.modalSheet,
      }}>
        <div style={{ width: 36, height: 4, background: T.elevated, borderRadius: 4, margin: '0 auto 18px' }}/>
        <div style={{ fontSize: 19, fontWeight: 600, color: T.text, letterSpacing: -0.3, marginBottom: 6 }}>Edit license plate</div>
        <div style={{ fontSize: 12.5, color: T.textSec, lineHeight: 1.45, marginBottom: 20 }}>Your Tesla doesn’t report its plate, so enter it manually. It appears on shared rides so passengers can spot the car.</div>
        <div style={{ fontSize: 10.5, color: T.textMuted, letterSpacing: 0.9, fontWeight: 600, textTransform: 'uppercase', marginBottom: 9 }}>Plate number</div>
        <input ref={inputRef} value={val}
          onChange={(e) => setVal(e.target.value.toUpperCase().replace(/[^A-Z0-9 -]/g, '').slice(0, 8))}
          onKeyDown={(e) => { if (e.key === 'Enter' && valid) onSave(clean); }}
          placeholder="e.g. RBO-2046"
          style={{
            width: '100%', boxSizing: 'border-box',
            background: 'rgba(255,255,255,0.05)', border: `1px solid ${valid || !clean ? T.border : '#FF6B6B66'}`,
            borderRadius: 14, padding: '15px 16px', color: T.text,
            fontFamily: T.fontNum, fontSize: 21, fontWeight: 600, letterSpacing: 3, textAlign: 'center',
            outline: 'none', textTransform: 'uppercase', fontVariantNumeric: 'tabular-nums',
          }}/>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 9, padding: '0 2px' }}>
          <span style={{ fontSize: 11, color: clean && !valid ? '#FF6B6B' : T.textMuted }}>{clean && !valid ? 'Enter at least 2 characters' : 'Letters, numbers, spaces or dashes'}</span>
          <span style={{ fontSize: 11, color: T.textMuted, fontVariantNumeric: 'tabular-nums' }}>{clean.length}/8</span>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 9, marginTop: 22 }}>
          <Button variant="gold" onClick={() => { if (valid && changed) onSave(clean); }}
            style={!(valid && changed) ? { opacity: 0.4, pointerEvents: 'none' } : undefined}>Save plate</Button>
          <Button variant="ghost" onClick={onCancel}>Cancel</Button>
        </div>
      </div>
    </div>
  );
  return ReactDOM.createPortal(modal, target);
}

const TRACKS = [
  { title: 'Midnight City', artist: 'M83', cover: 'linear-gradient(135deg, #2b3a67, #c9a84c)' },
  { title: 'Nightcall', artist: 'Kavinsky', cover: 'linear-gradient(135deg, #7b1e3b, #1a1a2e)' },
  { title: 'Resonance', artist: 'HOME', cover: 'linear-gradient(135deg, #0f3443, #34e89e)' },
];

function VehicleControls({ v, status = 'parked', battery = 68, speed = 64 }) {
  const driving = status === 'driving';
  // Live state
  const [locked, setLocked] = vcS(true);
  const [climateOn, setClimateOn] = vcS(true);
  const [temp, setTemp] = vcS(70);
  const [mode, setMode] = vcS('auto');        // auto | heat | cool
  const [fan, setFan] = vcS(3);
  const [driverHeat, setDriverHeat] = vcS(2);
  const [passHeat, setPassHeat] = vcS(0);
  const [driverMode, setDriverMode] = vcS('heat'); // heat | cool
  const [passMode, setPassMode] = vcS('heat');
  const seats = v.seats || { heat: true, vent: false };
  const [trunk, setTrunk] = vcS(false);
  const [chargePort, setChargePort] = vcS(false);
  const [plate, setPlate] = vcS(v.plate || '');
  const [editingPlate, setEditingPlate] = vcS(false);
  const [playing, setPlaying] = vcS(driving);
  const [trackIdx, setTrackIdx] = vcS(0);
  const [scrub, setScrub] = vcS(38);
  const [volume, setVolume] = vcS(45);

  const track = TRACKS[trackIdx];
  const rangeMi = Math.round((battery / 100) * 272);
  const cabinTemp = 66;   // actual measured interior temp (vs. `temp` setpoint)
  const extTemp = 58;     // outside air temp
  const tires = [['FL', 42], ['FR', 42], ['RL', 41], ['RR', 43]];

  const fmtTime = (p) => {
    const totalSec = Math.round((p / 100) * 222); // 3:42 track
    const m = Math.floor(totalSec / 60); const s = totalSec % 60;
    return `${m}:${String(s).padStart(2, '0')}`;
  };

  return (
    <div className="mrt-reveal" style={{ display: 'flex', flexDirection: 'column' }}>
      <Divider pad={6}/>

      {/* Quick controls */}
      <div style={{ display: 'flex', gap: 8 }}>
        <ControlTile icon={locked ? 'lock.fill' : 'lock.open.fill'} label={locked ? 'Locked' : 'Unlocked'}
          sub={locked ? 'Tap to unlock' : 'Tap to lock'} active={!locked} activeColor={T.driving}
          onClick={() => setLocked(l => !l)}/>
        <ControlTile icon="fan" label="Climate" sub={climateOn ? `On · ${temp}°` : 'Off'}
          active={climateOn} onClick={() => setClimateOn(c => !c)}/>
        <ControlTile icon="car.fill" label="Trunk" sub={trunk ? 'Open' : 'Closed'}
          active={trunk} activeColor={T.parked} onClick={() => setTrunk(f => !f)}/>
        <ControlTile icon="bolt.fill" label="Charge" sub={chargePort ? 'Port open' : 'Port closed'}
          active={chargePort} activeColor={T.charging} onClick={() => setChargePort(p => !p)}/>
      </div>

      {/* Climate */}
      <SectionCard title="Climate">
        {climateOn ? (
          <>
            {/* Temp big control */}
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 16, marginBottom: 16 }}>
              <button onClick={() => setTemp(t => Math.max(60, t - 1))} style={stepBtn}>
                <span style={{ fontSize: 22, color: T.text, fontWeight: 300, lineHeight: 1 }}>−</span>
              </button>
              <div style={{ textAlign: 'center' }}>
                <div style={{ fontFamily: T.fontNum, fontSize: 40, fontWeight: 300, color: T.text, lineHeight: 1, letterSpacing: -1, fontVariantNumeric: 'tabular-nums' }}>{temp}°</div>
                <div style={{ fontSize: 10.5, color: T.textMuted, letterSpacing: 0.6, fontWeight: 600, textTransform: 'uppercase', marginTop: 4 }}>Set temp</div>
                <div style={{ fontSize: 11, color: T.textMuted, marginTop: 6, fontVariantNumeric: 'tabular-nums' }}>Interior {cabinTemp}° · Outside {extTemp}°</div>
              </div>
              <button onClick={() => setTemp(t => Math.min(82, t + 1))} style={stepBtn}>
                <span style={{ fontSize: 22, color: T.text, fontWeight: 300, lineHeight: 1 }}>+</span>
              </button>
            </div>

            {/* Mode segmented */}
            <div style={{ display: 'flex', gap: 4, padding: 3, borderRadius: 11, background: 'rgba(255,255,255,0.05)', marginBottom: 14 }}>
              {[['auto', 'Auto'], ['cool', 'Cool'], ['heat', 'Heat']].map(([k, label]) => (
                <button key={k} onClick={() => setMode(k)} style={{
                  flex: 1, padding: '7px 6px', borderRadius: 8, border: 'none', cursor: 'pointer',
                  fontFamily: T.font, fontSize: 12.5, fontWeight: 600,
                  background: mode === k ? T.gold : 'transparent', color: mode === k ? '#1a1408' : T.textSec,
                  transition: 'background .15s, color .15s',
                }}>{label}</button>
              ))}
            </div>

            {/* Fan speed — Tesla-style level bar, clearly labelled */}
            <div style={{ marginBottom: 2 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <SFIcon name="wind" size={15} color={T.textSec}/>
                  <span style={{ fontSize: 12.5, color: T.textSec, fontWeight: 500 }}>Fan speed</span>
                </div>
                <span style={{ fontFamily: T.fontNum, fontSize: 12.5, color: T.text, fontWeight: 600, fontVariantNumeric: 'tabular-nums' }}>{fan} <span style={{ color: T.textMuted, fontWeight: 400 }}>/ 10</span></span>
              </div>
              <FanBar value={fan} onChange={setFan}/>
            </div>

            {/* Seats — heating always; ventilation too when the vehicle supports it */}
            <div style={{ paddingTop: 14, borderTop: `0.5px solid ${T.border}`, marginTop: 16 }}>
              <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 11, color: T.textMuted, fontWeight: 700, letterSpacing: 0.8, textTransform: 'uppercase' }}>{seats.vent ? 'Seat climate' : 'Seat heating'}</span>
                {seats.vent && <span style={{ fontSize: 10.5, color: T.textMuted, fontWeight: 500 }}>Heat &amp; ventilation</span>}
              </div>
              <SeatRow label="Driver" vent={seats.vent} mode={driverMode} setMode={setDriverMode} level={driverHeat} setLevel={setDriverHeat}/>
              <SeatRow label="Passenger" vent={seats.vent} mode={passMode} setMode={setPassMode} level={passHeat} setLevel={setPassHeat}/>
            </div>
          </>
        ) : (
          /* Off state — climate idle, but cabin + outside temps stay visible */
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 14, paddingBottom: 14, borderBottom: `0.5px solid ${T.border}` }}>
              <div style={{ width: 44, height: 44, borderRadius: 22, background: 'rgba(255,255,255,0.05)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                <SFIcon name="fan" size={20} color={T.textMuted}/>
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14, fontWeight: 600, color: T.text, letterSpacing: -0.2 }}>Climate off</div>
                <div style={{ fontSize: 12, color: T.textMuted, marginTop: 2 }}>Cabin idle · last set to {temp}°</div>
              </div>
              <button onClick={() => setClimateOn(true)} style={{
                flexShrink: 0, padding: '8px 16px', borderRadius: 20, border: 'none', cursor: 'pointer',
                fontFamily: T.font, fontSize: 12.5, fontWeight: 600, color: '#1a1408', background: T.gold,
                WebkitTapHighlightColor: 'transparent',
              }}>Turn on</button>
            </div>
            <div style={{ display: 'flex', paddingTop: 14 }}>
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 6 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                  <SFIcon name="car.fill" size={13} color={T.textMuted}/>
                  <span style={{ fontSize: 10.5, color: T.textMuted, fontWeight: 600, letterSpacing: 0.7, textTransform: 'uppercase' }}>Interior</span>
                </div>
                <span style={{ fontFamily: T.fontNum, fontSize: 26, fontWeight: 300, color: T.text, letterSpacing: -0.6, fontVariantNumeric: 'tabular-nums' }}>{cabinTemp}°</span>
              </div>
              <div style={{ width: '0.5px', background: T.border, margin: '2px 0' }}/>
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 6, paddingLeft: 18 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                  <SFIcon name="sun.max.fill" size={13} color={T.textMuted}/>
                  <span style={{ fontSize: 10.5, color: T.textMuted, fontWeight: 600, letterSpacing: 0.7, textTransform: 'uppercase' }}>Exterior</span>
                </div>
                <span style={{ fontFamily: T.fontNum, fontSize: 26, fontWeight: 300, color: T.text, letterSpacing: -0.6, fontVariantNumeric: 'tabular-nums' }}>{extTemp}°</span>
              </div>
            </div>
          </div>
        )}
      </SectionCard>

      {/* Media */}
      <SectionCard title="Media">
        <div style={{ display: 'flex', alignItems: 'center', gap: 13, marginBottom: 14 }}>
          <div style={{ width: 52, height: 52, borderRadius: 11, background: track.cover, flexShrink: 0, boxShadow: '0 2px 10px rgba(0,0,0,0.35)' }}/>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 15, fontWeight: 600, color: T.text, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{track.title}</div>
            <div style={{ fontSize: 12.5, color: T.textSec, marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{track.artist}</div>
          </div>
        </div>

        {/* Scrubber */}
        <Slider value={scrub} min={0} max={100} onChange={setScrub} height={4}/>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 6, marginBottom: 10, fontFamily: T.fontNum, fontSize: 10.5, color: T.textMuted, fontVariantNumeric: 'tabular-nums' }}>
          <span>{fmtTime(scrub)}</span><span>3:42</span>
        </div>

        {/* Transport */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 30 }}>
          <button onClick={() => { setTrackIdx(i => (i + TRACKS.length - 1) % TRACKS.length); setScrub(0); }} style={iconBtn}>
            <SFIcon name="backward.fill" size={22} color={T.text}/>
          </button>
          <button onClick={() => setPlaying(p => !p)} style={{ ...iconBtn, width: 54, height: 54, borderRadius: 27, background: T.gold }}>
            <SFIcon name={playing ? 'pause.fill' : 'play.fill'} size={22} color="#1a1408"/>
          </button>
          <button onClick={() => { setTrackIdx(i => (i + 1) % TRACKS.length); setScrub(0); }} style={iconBtn}>
            <SFIcon name="forward.fill" size={22} color={T.text}/>
          </button>
        </div>

        {/* Volume */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 16 }}>
          <SFIcon name="speaker.wave.2.fill" size={15} color={T.textSec}/>
          <Slider value={volume} min={0} max={100} onChange={setVolume} height={4}/>
        </div>
      </SectionCard>

      {/* Status & location — parked only; while driving, live speed, heading,
         and range already live at the top of the sheet. */}
      {!driving && (
        <SectionCard title="Status & location" right={
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
            <span style={{ width: 7, height: 7, borderRadius: 4, background: T.parked, boxShadow: `0 0 7px ${T.parked}aa` }}/>
            <span style={{ fontSize: 12, fontWeight: 600, color: T.parked }}>Parked</span>
          </span>
        }>
          <KV label="Location" value="Embarcadero Ctr"/>
          <KV label="Parked" value="1h 42m"/>
          <KV label="Range" value={`${rangeMi} mi`}/>
        </SectionCard>
      )}

      {/* Tire pressure */}
      <SectionCard title="Tire pressure" right={<span style={{ fontSize: 11.5, color: T.driving, fontWeight: 600 }}>All nominal</span>}>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '14px 0' }}>
          {tires.map(([pos, psi]) => (
            <div key={pos} style={{ display: 'flex', alignItems: 'center', gap: 10, justifyContent: pos.endsWith('L') ? 'flex-start' : 'flex-end' }}>
              {pos.endsWith('L') && <span style={{ fontSize: 10.5, color: T.textMuted, fontWeight: 600, letterSpacing: 0.5 }}>{pos}</span>}
              <span style={{ fontFamily: T.fontNum, fontSize: 17, fontWeight: 500, color: T.text, fontVariantNumeric: 'tabular-nums', letterSpacing: -0.3 }}>{psi}<span style={{ fontSize: 10, color: T.textMuted, marginLeft: 2, fontWeight: 400 }}>psi</span></span>
              {pos.endsWith('R') && <span style={{ fontSize: 10.5, color: T.textMuted, fontWeight: 600, letterSpacing: 0.5 }}>{pos}</span>}
            </div>
          ))}
        </div>
      </SectionCard>

      {/* Lifetime */}
      <SectionCard title="Lifetime">
        <KV label="Odometer" value="42,184 mi"/>
        <KV label="Total FSD miles" value="31,907 mi" gold/>
        <KV label="Driven autonomously" value="76%"/>
      </SectionCard>

      {/* Vehicle details */}
      <SectionCard title="Vehicle details">
        <KV label="Model" value={v.model}/>
        <KV label="Color" value={v.color}/>
        <PlateRow value={plate} onEdit={() => setEditingPlate(true)}/>
        <KV label="VIN" value="7SAYGDEE9PA142184"/>
        <KV label="Software" value="2026.14.3"/>
      </SectionCard>

      <div style={{ marginTop: 16, fontSize: 10, color: T.textMuted, textAlign: 'center', letterSpacing: 0.3 }}>
        Updated just now · Live
      </div>

      {editingPlate && (
        <PlateEditModal initial={plate}
          onCancel={() => setEditingPlate(false)}
          onSave={(p) => { setPlate(p); setEditingPlate(false); }}/>
      )}
    </div>
  );
}

const stepBtn = {
  width: 46, height: 46, borderRadius: 23, flexShrink: 0,
  background: 'rgba(255,255,255,0.06)', border: `0.5px solid ${T.border}`,
  display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer',
  WebkitTapHighlightColor: 'transparent',
};
const iconBtn = {
  width: 44, height: 44, borderRadius: 22, border: 'none', background: 'transparent',
  display: 'flex', alignItems: 'center', justifyContent: 'center', cursor: 'pointer',
  WebkitTapHighlightColor: 'transparent', padding: 0,
};

Object.assign(window, { VehicleControls });
