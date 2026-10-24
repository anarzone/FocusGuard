import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Conn, connFromDisconnect } from '../src/lib/protocol.js';
import { barSegments, breakClock, passFor, presetRules, ringArcs, sessionClock, toolbar } from '../src/lib/view.js';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/state-focusing.json', import.meta.url)));
const asOf = fixture.session.asOf;

test('the session clock runs on from asOf', () => {
  const now = sessionClock(fixture.session, asOf);
  assert.equal(now.elapsed, 1620);
  assert.equal(now.left, 3000 - 1620);
  assert.equal(now.endsAt, fixture.session.endsAt);
  const later = sessionClock(fixture.session, asOf + 60_000);
  assert.equal(later.elapsed, 1680);
  assert.equal(later.left, 1320);
});

test('a paused session holds still', () => {
  const paused = { ...fixture.session, paused: true, endsAt: null };
  const c = sessionClock(paused, asOf + 600_000);
  assert.equal(c.elapsed, 1620);
  assert.equal(c.left, 1380);
  assert.equal(c.endsAt, null);
});

test('open-ended sessions count up and scale the bar to the next half hour', () => {
  const open = { ...fixture.session, plannedMinutes: null, endsAt: null };
  const c = sessionClock(open, asOf);
  assert.equal(c.left, null);
  assert.equal(c.progress, null);
  const bar = barSegments(open, asOf);
  assert.equal(Math.round(bar.reduce((sum, s) => sum + s.pct, 0)), Math.round((1620 / 1800) * 100));
});

test('bar segments are shares of the planned length', () => {
  const bar = barSegments(fixture.session, asOf);
  assert.deepEqual(bar.map((s) => s.kind), ['f', 'o', 'f', 'd', 'f']);
  assert.equal(bar[0].pct, 24);
  assert.equal(bar[3].pct, 4);
});

test('break clock', () => {
  const info = { startedAt: 0, endsAt: 600_000, plannedSeconds: 600, canEndEarly: true };
  const c = breakClock(info, 138_000);
  assert.equal(c.left, 462);
  assert.equal(Math.round(c.progress * 100), 23);
});

// The app's OverridePolicy values for each preset.
const policies = {
  gentle: { allowsPass: true, passWaitSeconds: 0, passSeconds: 120, forWorkWaitSeconds: 0, locksDuringSession: false,
    extraTime: { minutes: 5, timesPerDay: 3, waitSeconds: 0 }, limitChangesWaitForTomorrow: false },
  strict: { allowsPass: false, passWaitSeconds: 0, passSeconds: 120, forWorkWaitSeconds: 10, locksDuringSession: true,
    extraTime: { minutes: 5, timesPerDay: 0, waitSeconds: 0 }, limitChangesWaitForTomorrow: true },
};

test('block page rules come from the policy the app sends', () => {
  assert.deepEqual(presetRules(fixture.policy), {
    pass: true, passWait: 5, passSeconds: 120, forWorkWait: 0, locks: false,
    extra: { minutes: 5, waitSeconds: 5, timesPerDay: 1 }, limitChangesWaitForTomorrow: false,
  });
  assert.deepEqual(presetRules(policies.gentle).extra, { minutes: 5, waitSeconds: 0, timesPerDay: 3 });
  const strict = presetRules(policies.strict);
  assert.equal(strict.pass, false);
  assert.equal(strict.forWorkWait, 10);
  assert.equal(strict.extra, null);
  assert.equal(strict.limitChangesWaitForTomorrow, true);
  assert.deepEqual(presetRules(undefined), presetRules(fixture.policy));
});

test('toolbar: off, ready, focusing with a pass badge, break, done', () => {
  assert.equal(toolbar({ conn: Conn.notRunning, state: null }).kind, 'off');
  assert.equal(toolbar({ conn: Conn.notRunning, state: null }).title, "FocusGuard isn't running");
  assert.equal(toolbar({ conn: Conn.connected, state: { ...fixture, phase: 'ready', session: undefined } }).kind, 'ready');

  const focusing = toolbar({ conn: Conn.connected, state: fixture, now: asOf, activeHost: 'news.ycombinator.com' });
  assert.equal(focusing.kind, 'focus');
  assert.equal(focusing.badge, null);
  assert.equal(focusing.title, 'FocusGuard · 23 min left · 6 sites blocked');
  assert.ok(Math.abs(focusing.fill - 0.54) < 0.001);

  const withBadge = toolbar({ conn: Conn.connected, state: fixture, now: asOf, activeHost: 'news.ycombinator.com', badgeMinutes: true });
  assert.deepEqual(withBadge.badge, { text: '23', color: '#6155F5', textColor: '#FFFFFF' });

  const pass = toolbar({ conn: Conn.connected, state: fixture, now: asOf, activeHost: 'www.x.com' });
  // Orange with dark digits, never orange text.
  assert.deepEqual(pass.badge, { text: '1:20', color: '#FF8D28', textColor: '#1D1D1F' });
  assert.ok(passFor(fixture, 'x.com', asOf));
  assert.equal(passFor(fixture, 'x.com', asOf + 90_000), null);

  const brk = toolbar({ conn: Conn.connected, state: { ...fixture, phase: 'break', break: { endsAt: asOf + 300_000 } }, now: asOf });
  assert.equal(brk.kind, 'break');
  assert.match(brk.title, /^FocusGuard · break until /);

  const done = toolbar({ conn: Conn.connected, state: { ...fixture, phase: 'complete', recap: { name: 'Evening focus', endedAt: asOf, showUntil: asOf + 900_000 } }, now: asOf });
  assert.equal(done.kind, 'done');
  const later = toolbar({ conn: Conn.connected, state: { ...fixture, phase: 'complete', recap: { name: 'Evening focus', endedAt: asOf, showUntil: asOf + 900_000 } }, now: asOf + 901_000 });
  assert.equal(later.kind, 'ready');
});

test('ring arcs: one path per kind, knob at the end of tracked time', () => {
  const arcs = ringArcs(fixture.session.segments, 3000);
  assert.ok(arcs.f.startsWith('M'));
  assert.equal((arcs.f.match(/M/g) || []).length, 3);
  assert.equal((arcs.d.match(/M/g) || []).length, 1);
  assert.equal((arcs.o.match(/M/g) || []).length, 1);
  assert.equal(arcs.lastKind, 'f');
  // 1620 of 3000 s is 194.4°, left of the bottom.
  assert.ok(arcs.knobX < 84 && arcs.knobY > 84);
  const empty = ringArcs([], 3000);
  assert.equal(empty.f + empty.d + empty.o, '');
});

test('connect errors map to the popup states', () => {
  assert.equal(connFromDisconnect('Specified native messaging host not found.'), Conn.notInstalled);
  assert.equal(connFromDisconnect('Access to the specified native messaging host is forbidden.'), Conn.notInstalled);
  assert.equal(connFromDisconnect('Native host has exited.'), Conn.notRunning);
});
