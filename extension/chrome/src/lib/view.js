// What the toolbar button, popup and block pages show, worked out from the
// app's state and the clock. Pure, so it's tested in Node.

import { Conn } from './protocol.js';
import { clock, minutesLabel, timeOfDay } from './format.js';
import { hostMatches } from './blocking.js';

// Running time, time left and the end, as of `now`. The app sends elapsed
// time as of `asOf`, so the countdown runs here without a message a second.
export function sessionClock(session, now = Date.now()) {
  if (!session) return null;
  const running = !session.paused;
  const elapsed = session.elapsedSeconds + (running ? Math.max(0, (now - session.asOf) / 1000) : 0);
  const planned = session.plannedMinutes ? session.plannedMinutes * 60 : null;
  const left = planned === null ? null : Math.max(0, planned - elapsed);
  const endsAt = session.endsAt ?? (left !== null && running ? now + left * 1000 : null);
  const progress = planned ? Math.min(1, elapsed / planned) : null;
  return { elapsed, planned, left, endsAt, progress };
}

export function breakClock(info, now = Date.now()) {
  if (!info) return null;
  const left = Math.max(0, (info.endsAt - now) / 1000);
  const progress = info.plannedSeconds > 0 ? Math.min(1, 1 - left / info.plannedSeconds) : 1;
  return { left, progress, endsAt: info.endsAt };
}

// The session bar: each stretch as a share of the whole session (the
// planned length, or for open-ended sessions the next half hour).
export function barSegments(session, now = Date.now()) {
  const c = sessionClock(session, now);
  if (!c) return [];
  const scale = c.planned ?? Math.max(1800, Math.ceil(c.elapsed / 1800) * 1800);
  return (session.segments || [])
    .map(([kind, seconds]) => ({ kind, pct: Math.max(0, (seconds / scale) * 100) }))
    .filter((s) => s.pct > 0);
}

// Standard's rules, for a state from before the app sent its policy.
const STANDARD_POLICY = {
  allowsPass: true, passWaitSeconds: 5, passSeconds: 120, forWorkWaitSeconds: 0, locksDuringSession: false,
  extraTime: { minutes: 5, timesPerDay: 1, waitSeconds: 5 }, limitChangesWaitForTomorrow: false,
};

// What the block pages offer, from the app's OverridePolicy for the preset
// in force: passes, the waits before buttons unlock, extra time on limits.
export function presetRules(policy) {
  const p = policy || STANDARD_POLICY;
  const extra = p.extraTime || {};
  return {
    pass: !!p.allowsPass,
    passWait: p.passWaitSeconds || 0,
    passSeconds: p.passSeconds || 120,
    forWorkWait: p.forWorkWaitSeconds || 0,
    locks: !!p.locksDuringSession,
    extra: extra.timesPerDay > 0 ? { minutes: extra.minutes, waitSeconds: extra.waitSeconds || 0, timesPerDay: extra.timesPerDay } : null,
    limitChangesWaitForTomorrow: !!p.limitChangesWaitForTomorrow,
  };
}

export function presetName(preset) {
  return { gentle: 'Gentle', standard: 'Standard', strict: 'Strict' }[preset] || 'Standard';
}

// The pass running on this host, if any.
export function passFor(state, host, now = Date.now()) {
  if (!host) return null;
  return (state?.blocking?.passes || []).find((p) => p.until > now && (hostMatches(host, p.host) || hostMatches(p.host, host))) || null;
}

// The toolbar button: which glyph, how full, the badge and the tooltip.
//   kind: off | ready | focus | paused | break | done
export function toolbar({ conn, state, now = Date.now(), activeHost = null, badgeMinutes = false }) {
  if (conn !== Conn.connected || !state) {
    return { kind: 'off', fill: 0, badge: null, title: "FocusGuard isn't running" };
  }
  const features = state.plan?.features || {};
  const blockedCount = features.blockInBrowser
    ? (state.blocking?.sites?.length || 0) + (features.partsOfSites ? state.blocking?.parts?.length || 0 : 0)
    : 0;
  switch (state.phase) {
    case 'focusing':
    case 'paused': {
      const c = sessionClock(state.session, now);
      const fill = c.progress ?? Math.min(1, c.elapsed / 3600);
      const pass = passFor(state, activeHost, now);
      let badge = null;
      if (pass) {
        badge = { text: clock((pass.until - now) / 1000), color: '#FF8D28', textColor: '#1D1D1F' };
      } else if (badgeMinutes && c.left !== null && state.phase === 'focusing') {
        badge = { text: String(Math.ceil(c.left / 60)), color: '#6155F5', textColor: '#FFFFFF' };
      }
      const parts = ['FocusGuard'];
      if (state.phase === 'paused') parts.push('paused');
      else parts.push(c.left !== null ? `${Math.ceil(c.left / 60)} min left` : `${minutesLabel(c.elapsed)} so far`);
      if (pass) parts.push(`let through for ${clock((pass.until - now) / 1000)}`);
      else if (blockedCount > 0 && state.phase === 'focusing') parts.push(`${blockedCount} ${blockedCount === 1 ? 'site' : 'sites'} blocked`);
      return { kind: state.phase === 'paused' ? 'paused' : 'focus', fill, badge, title: parts.join(' · ') };
    }
    case 'break':
      return {
        kind: 'break', fill: 0, badge: null,
        title: `FocusGuard · break until ${timeOfDay(state.break?.endsAt ?? now)}`,
      };
    case 'complete':
      if (state.recap && state.recap.showUntil > now) {
        return { kind: 'done', fill: 1, badge: null, title: `FocusGuard · ${state.recap.name} is done` };
      }
      return { kind: 'ready', fill: 0, badge: null, title: 'FocusGuard · ready' };
    default:
      return { kind: 'ready', fill: 0, badge: null, title: 'FocusGuard · ready' };
  }
}

// Arcs for the session ring on the block pages: focus, drift and other in
// session order, as SVG path data, plus where the knob sits.
export function ringArcs(segments, totalSeconds, { center = 84, radius = 70, gapDegrees = 1.6 } = {}) {
  const total = Math.max(1, totalSeconds);
  const out = { f: '', d: '', o: '', knobX: center, knobY: center - radius, lastKind: 'f' };
  const point = (deg) => {
    const t = ((deg - 90) * Math.PI) / 180;
    return { x: center + radius * Math.cos(t), y: center + radius * Math.sin(t) };
  };
  let at = 0;
  const runs = [];
  for (const [kind, seconds] of segments) {
    if (seconds <= 0) continue;
    const last = runs[runs.length - 1];
    if (last && last.kind === kind) last.b += seconds;
    else runs.push({ kind, a: at, b: at + seconds });
    at += seconds;
  }
  runs.forEach((run, n) => {
    const a0 = (Math.min(run.a, total) / total) * 360 + (n > 0 ? gapDegrees / 2 : 0);
    const a1 = (Math.min(run.b, total) / total) * 360 - (n < runs.length - 1 ? gapDegrees / 2 : 0);
    if (a1 <= a0) return;
    const p0 = point(a0);
    const p1 = point(Math.min(a1, 359.99));
    out[run.kind] += `M${p0.x.toFixed(2)} ${p0.y.toFixed(2)} A${radius} ${radius} 0 ${a1 - a0 > 180 ? 1 : 0} 1 ${p1.x.toFixed(2)} ${p1.y.toFixed(2)} `;
  });
  const knob = point((Math.min(at, total) / total) * 360);
  out.knobX = Number(knob.x.toFixed(2));
  out.knobY = Number(knob.y.toFixed(2));
  out.lastKind = runs.length ? runs[runs.length - 1].kind : 'f';
  return out;
}
