// The page a tab shows instead of a distracting site.
//   kind=paused  free: the tab was set aside when the Mac's block screen came
//                up. The app's fields follow the "#", the same ones its own
//                paused.html takes (id, host, url, state, ends, back,
//                minutes), and the app changes them as the state moves on.
//   kind=site    Pro: a blocked site, kept from loading
//   kind=part    Pro: a blocked part of a site (youtube.com/shorts)
//   kind=limit   Pro: a site over its daily limit
// For the Pro kinds the original address follows the "#", unescaped.

import { Conn } from '../src/lib/protocol.js';
import { clock, displayHost, minutesPhrase, parseFragment, safeWebURL, splitPart, timeOfDay } from '../src/lib/format.js';
import { ordinal, plural, t } from '../src/lib/i18n.js';
import { presetName, presetRules, ringArcs, sessionClock } from '../src/lib/view.js';
import { h, icons, localizePage, mount, reportAppearance, siteTile, subscribe, tell, waitDial } from '../src/lib/dom.js';

const params = new URLSearchParams(location.search);
const kind = params.get('kind') || 'paused';
const target = params.get('target') || '';
const openedAt = Date.now();
let fields = {};
let originalURL = '';
let host = '';           // the site's name as the page shows it
let reportedHost = '';   // and as the app hears it, never translated
readAddress();

const app = document.getElementById('app');
let snap = null;
let renderedKey = '';
let live = [];
let busy = false;

// No site name in the title: title rules must never match this page.
document.title = kind === 'paused' ? t('blockDocTitlePaused') : t('blockDocTitleBlocked');
// The app moves a paused tab on by changing the fields after the "#".
window.addEventListener('hashchange', () => {
  readAddress();
  renderedKey = '';
  render();
});
localizePage();
reportAppearance();
subscribe('block', (next) => { snap = next; render(); });
setInterval(() => live.forEach((update) => update(Date.now())), 250);
document.addEventListener('keydown', onKey);

// Count a stopped visit once per page load (not on reloads of the same page).
if (kind !== 'paused') {
  const mark = `counted:${location.href}`;
  try {
    if (!sessionStorage.getItem(mark)) {
      sessionStorage.setItem(mark, '1');
      tell({ type: 'blockedVisit', host: reportedHost });
    }
  } catch {
    tell({ type: 'blockedVisit', host: reportedHost });
  }
}

function readAddress() {
  let known;
  if (kind === 'paused') {
    fields = parseFragment(location.hash);
    originalURL = safeWebURL(fields.url) || '';
    known = fields.host || displayHost(originalURL);
  } else {
    originalURL = decodeOriginal(location.hash.slice(1));
    known = displayHost(originalURL) || target;
  }
  host = known || t('blockThisSite');
  reportedHost = known || 'This site';
}

function decodeOriginal(raw) {
  if (!raw) return '';
  if (/^https?:/i.test(raw)) return raw;
  try { return decodeURIComponent(raw); } catch { return raw; }
}

// ---------------------------------------------------------------------------
// Actions

async function backToWork() {
  if (busy) return;
  busy = true;
  await tell({ type: 'backToWork' });
  busy = false;
}

async function letMeThrough() {
  if (busy) return;
  busy = true;
  const reply = await tell({ type: 'passThrough', url: originalURL });
  busy = false;
  if (!reply?.ok) showProblem(reply?.error);
}

async function forWork() {
  if (busy) return;
  busy = true;
  const reply = await tell({ type: 'forWork', url: originalURL });
  busy = false;
  if (!reply?.ok) showProblem(reply?.error);
}

async function extraTime() {
  if (busy) return;
  busy = true;
  const reply = await tell({ type: 'extraTime', site: target || reportedHost, url: originalURL });
  busy = false;
  if (!reply?.ok) showProblem(reply?.error);
}

async function reopen() {
  const reply = await tell({ type: 'reopenTab', url: originalURL });
  // Not a paused tab any more (e.g. after a browser restart): just go.
  if (!reply?.ok && originalURL) tell({ type: 'goTo', url: originalURL });
}

// The paused page's buttons go to the app, like paused.html's links.
async function tabAction(action, extra = {}) {
  if (busy) return;
  busy = true;
  const reply = await tell({ type: 'tabAction', action, pauseId: fields.id, ...extra });
  busy = false;
  if (!reply?.ok) showProblem(reply?.error);
}

function closeTab() {
  tell({ type: 'closeTab' });
}

let problem = null;
function showProblem(error) {
  problem = {
    strict: t('blockProblemStrict'),
    notPro: t('blockProblemNotPro'),
    noSession: t('blockProblemNoSession'),
    notAllowed: t('blockProblemNoExtraTime'),
    notConnected: t('blockProblemNotConnected'),
    notRunning: t('blockProblemNotOpen'),
  }[error] || t('blockProblemGeneric');
  renderedKey = '';
  render();
}

// Keys: esc goes back to work (or closes the tab), return takes the
// main way through once it's unlocked.
let keyActions = { esc: null, enter: null };
function onKey(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.key === 'Escape' && keyActions.esc) {
    event.preventDefault();
    keyActions.esc();
  } else if (event.key === 'Enter' && keyActions.enter && !(event.target instanceof HTMLButtonElement)) {
    const action = keyActions.enter();
    if (action) {
      event.preventDefault();
      action();
    }
  }
}

// ---------------------------------------------------------------------------
// Rendering

function render() {
  if (!snap) return;
  const state = snap.state;
  const key = JSON.stringify({
    conn: snap.conn, phase: state?.phase, plan: state?.plan, preset: state?.preset, policy: state?.policy,
    session: state?.session && { name: state.session.name, paused: state.session.paused, backTo: state.session.backTo, visits: state.session.stoppedVisits, segments: state.session.segments },
    blocking: state?.blocking, problem, fields,
  });
  if (key === renderedKey) return;
  renderedKey = key;
  live = [];
  keyActions = { esc: null, enter: null };
  mount(app, view(state));
  live.forEach((update) => update(Date.now()));
}

function view(state) {
  const connected = snap.conn === Conn.connected && state;
  const running = connected && (state.phase === 'focusing' || state.phase === 'paused');
  if (kind === 'paused') return pausedView(state);
  if (kind === 'limit') return limitView(state, connected);
  if (!running) return overView(state);
  return blockedView(state);
}

function sitePill(tag, tagClass = '') {
  const label = kind === 'part'
    ? h('span', { class: 'host' }, h('strong', null, splitPart(target).host), splitPart(target).path)
    : h('span', { class: 'host' }, h('strong', null, host));
  return h('div', { class: 'site-pill' }, siteTile(kind === 'part' ? splitPart(target).host : host, { size: 20, round: true }), label,
    tag ? h('span', { class: `tag ${tagClass}` }, tag) : null);
}

function backLabel(state) {
  const name = state?.session?.backTo;
  return name ? t('backTo', name) : t('closeTab');
}

function backAction(state) {
  return state?.session?.backTo ? backToWork : closeTab;
}

// The session ring, live: focus, drift and other so far, time left inside.
function ring(state) {
  const s = state.session;
  const c0 = sessionClock(s);
  const total = c0.planned ?? Math.max(1800, Math.ceil(c0.elapsed / 1800) * 1800);
  const arcs = ringArcs(s.segments || [], total);
  const knobColor = { f: 'var(--indigo-fill)', d: 'var(--orange)', o: 'var(--other)' }[arcs.lastKind];
  const big = h('div', { class: 'big num' });
  const small = h('div', { class: 'small' });
  const box = h('div', { class: 'ring', role: 'img' },
    h('svg', { width: 168, height: 168, viewBox: '0 0 168 168', 'aria-hidden': 'true' },
      h('circle', { cx: 84, cy: 84, r: 70, fill: 'none', stroke: 'var(--track)', 'stroke-width': 12 }),
      arcs.o ? h('path', { d: arcs.o, fill: 'none', stroke: 'var(--other)', 'stroke-width': 12 }) : null,
      arcs.d ? h('path', { d: arcs.d, fill: 'none', stroke: 'var(--orange)', 'stroke-width': 12 }) : null,
      arcs.f ? h('path', { d: arcs.f, fill: 'none', stroke: 'var(--indigo-fill)', 'stroke-width': 12 }) : null,
      h('circle', { cx: arcs.knobX, cy: arcs.knobY, r: 8, fill: '#FFFFFF', stroke: knobColor, 'stroke-width': 3 })),
    h('div', { class: 'center' }, big, small));
  live.push((now) => {
    const c = sessionClock(s, now);
    big.textContent = clock(c.left ?? c.elapsed);
    small.textContent = c.left !== null ? (s.paused ? t('clockLeftPaused') : t('clockLeft')) : t('clockSoFar');
    const done = Math.round(c.elapsed / 60);
    const planned = Math.round((c.planned || 0) / 60);
    const drift = Math.round(s.driftSeconds / 60);
    const shown = clock(c.left ?? c.elapsed);
    box.setAttribute('aria-label', !c.planned ? t('blockRingOpen', done, drift, shown)
      : c.endsAt ? t('blockRingEnds', done, planned, drift, shown, timeOfDay(c.endsAt))
        : t('blockRingPlanned', done, planned, drift, shown));
  });
  return box;
}

// A button that unlocks after `wait` seconds from when the page opened.
function waitButton(label, wait, onclick, { quiet = false } = {}) {
  const button = h('button', { class: `btn ${quiet ? 'btn-quiet' : 'btn-plain'}`, onclick });
  if (wait <= 0) {
    button.append(label);
    if (!quiet) button.append(icons.arrow());
    return button;
  }
  const paint = (now) => {
    const left = wait - (now - openedAt) / 1000;
    if (left > 0) {
      button.disabled = true;
      button.setAttribute('aria-label', t('blockAvailableIn', label, Math.ceil(left)));
      button.replaceChildren(waitDial(left, wait), label);
    } else if (button.disabled) {
      button.disabled = false;
      button.removeAttribute('aria-label');
      button.replaceChildren(label);
      if (!quiet) button.append(icons.arrow());
    }
  };
  live.push(paint);
  return button;
}

function keys(...items) {
  return h('div', { class: 'keys' }, items.filter(Boolean).map(([key, text]) => h('span', null, h('kbd', null, key), text)));
}

function footer(...parts) {
  return h('div', { class: 'footer' }, parts.filter(Boolean));
}

function changeLink(label = t('blockChangeBlocked')) {
  return h('a', { href: '#', onclick: (e) => { e.preventDefault(); tell({ type: 'openApp', page: 'blocking' }); } }, label);
}

function problemLine() {
  return problem ? h('p', { class: 'why', role: 'alert' }, problem) : null;
}

// --- Pro: blocked site or part ---------------------------------------------

function blockedView(state) {
  const s = state.session;
  const preset = state.preset;
  const rules = presetRules(state.policy);
  const c = sessionClock(s);
  const until = c.endsAt ? timeOfDay(c.endsAt) : null;
  const back = backAction(state);
  const name = presetName(preset);
  const visits = s.stoppedVisits;

  let title;
  let lede;
  if (kind === 'part') {
    const { host: partHost } = splitPart(target);
    title = t('blockPartTitle', partHost);
    lede = t('blockPartLede', partHost);
  } else if (!rules.pass) {
    title = until ? t('blockStrictTitleUntil', host, until) : t('blockStrictTitleSession', host);
    lede = t('blockStrictLede', s.name);
  } else {
    title = until ? t('blockWaitTitleUntil', host, until) : t('blockWaitTitleSession', host);
    lede = t('blockWaitLede', s.name);
  }

  const buttons = [h('button', { class: 'btn btn-primary', onclick: back }, backLabel(state))];
  if (kind === 'part') {
    const partHost = splitPart(target).host;
    buttons.push(h('button', { class: 'btn btn-quiet', onclick: () => tell({ type: 'goTo', url: `https://${partHost}/` }) }, t('blockGoTo', partHost)));
  } else if (rules.forWorkWait > 0) {
    buttons.push(waitButton(t('blockForWork'), rules.forWorkWait, forWork, { quiet: true }));
  } else {
    buttons.push(h('button', { class: 'btn btn-quiet', onclick: forWork }, t('blockForWork')));
  }
  let passButton = null;
  if (rules.pass) {
    passButton = waitButton(t('blockLetMeThrough'), rules.passWait, letMeThrough);
    buttons.push(passButton);
  } else if (kind !== 'part') {
    buttons.push(h('button', { class: 'btn btn-quiet', onclick: closeTab }, t('closeTab')));
  }

  keyActions.esc = back;
  keyActions.enter = () => (passButton && !passButton.disabled ? letMeThrough : null);

  const footerText = !rules.pass
    ? [t('blockFooterBy'), t('presetStrict'), until ? t('blockFooterLockedUntil', until) : t('blockFooterLockedSession')].join(' · ')
    : `${[t('blockFooterBy'), name, kind === 'part' ? t('blockFooterOnlyPart', target) : null, visits > 0 ? ordinal('blockFooterNth', visits) : null].filter(Boolean).join(' · ')} ·`;

  return [
    sitePill(t('categoryDistracting'), 'drift'),
    h('h1', null, title),
    h('p', { class: 'lede' }, lede),
    ring(state),
    h('div', { class: 'actions' }, buttons),
    !rules.pass && kind !== 'part'
      ? h('p', { class: 'why' }, t('blockWhyForWork', host, rules.forWorkWait))
      : null,
    problemLine(),
    keys(
      [t('keyEsc'), state.session.backTo ? t('backToKey', state.session.backTo) : t('closeTabKey')],
      rules.pass ? [t('keyReturn'), t('blockKeyLetThrough', minutesPhrase(rules.passSeconds))] : null,
    ),
    footer(h('span', null, footerText), rules.pass ? changeLink() : null),
  ];
}

// --- Pro: daily limit -------------------------------------------------------

function limitView(state, connected) {
  const site = target || host;
  const limit = connected ? (state.blocking.limits || []).find((l) => l.site === site) : null;
  const preset = state?.preset || 'standard';
  const rules = presetRules(state?.policy);
  const extraOffered = !!rules.extra && (limit?.extraLeft || 0) > 0;
  const minutes = limit?.minutes;
  const title = !extraOffered
    ? t('limitDoneTitle', site)
    : minutes ? t('limitMinutesTitle', minutes, site) : t('limitTimeTitle', site);
  let lede = t('limitLedeExtra');
  if (!extraOffered && rules.extra) lede = minutes ? t('limitLedeMinutes', minutes) : t('limitLedeUsed');
  if (!extraOffered && !rules.extra) lede = minutes ? t('limitLedeMinutesPreset', minutes, presetName(preset)) : t('limitLedeUsedPreset', presetName(preset));

  const buttons = [h('button', { class: 'btn btn-primary', onclick: closeTab }, t('closeTab'))];
  let extraButton = null;
  if (extraOffered) {
    extraButton = waitButton(t('limitMoreMinutes', rules.extra.minutes), rules.extra.waitSeconds, extraTime, { quiet: true });
    buttons.push(extraButton);
  }
  keyActions.esc = closeTab;
  keyActions.enter = () => (extraButton && !extraButton.disabled ? extraTime : null);
  const extraHint = !extraOffered ? null
    : rules.extra.timesPerDay === 1 ? t('limitOnceADay') : plural('limitTimesLeft', limit.extraLeft);

  const used = limit ? Math.round(limit.usedSeconds / 60) : minutes;
  return [
    sitePill(minutes ? t('limitTagMinutes', minutes) : t('limitTag')),
    h('h1', null, title),
    h('p', { class: 'lede' }, lede),
    limit ? h('section', { class: 'limit-card', 'aria-label': t('limitTodayOn', site) },
      h('div', { class: 'top' },
        h('span', { class: 'title' }, t('limitTodayOn', site)),
        h('span', { class: 'used num' }, t('limitUsedOf', used, minutes))),
      h('div', { class: 'meter', role: 'img', 'aria-label': t('limitMeterLabel', used, minutes, limit.visits) },
        h('div', { style: { width: `${Math.min(100, (limit.usedSeconds / (minutes * 60)) * 100)}%` } })),
      h('div', { class: 'bottom' },
        h('span', null, limit.visits
          ? (limit.lastVisitAt ? plural('limitVisitsLast', limit.visits, timeOfDay(limit.lastVisitAt)) : plural('limitVisits', limit.visits))
          : ''),
        h('span', null, t('limitResets')))) : null,
    h('div', { class: 'actions' }, buttons),
    problemLine(),
    keys([t('keyEsc'), t('closeTabKey')], extraButton ? [t('keyReturn'), t('limitKeyExtra', rules.extra.minutes, extraHint)] : null),
    footer(h('span', null, t('limitFooter', presetName(preset))),
      changeLink(rules.limitChangesWaitForTomorrow ? t('limitChangeTomorrow') : t('limitChange'))),
  ];
}

// --- Free: paused tab -------------------------------------------------------
// The same four states as the app's paused.html: paused (during a session),
// queued (reopens when it ends), over (the session ended) and limit.

function pausedState(now = Date.now()) {
  const ends = Number(fields.ends) || 0;
  const left = ends ? ends - now / 1000 : null;
  let state = fields.state || 'paused';
  // If the app couldn't say the session ended (it quit), don't trap the tab.
  if ((state === 'paused' || state === 'queued') && left !== null && left < -120) state = 'over';
  return { state, left };
}

function pausedView(state) {
  const back = fields.back ? t('backTo', fields.back) : t('backToWork');
  const goBack = () => tabAction('back');
  const { state: pageState, left } = pausedState();
  const running = state?.session && (state.phase === 'focusing' || state.phase === 'paused');
  const pro = !!state?.plan?.features?.blockInBrowser;
  const reopenSite = originalURL ? h('button', { class: 'btn btn-quiet', onclick: reopen }, t('pausedReopenHost', host)) : null;

  let title;
  let lede;
  let buttons;
  let tag = t('pausedTag');
  keyActions.esc = goBack;
  if (pageState === 'queued') {
    title = t('pausedQueuedTitle', host);
    lede = t('pausedQueuedLede');
    tag = t('pausedTagLater');
    buttons = [
      h('button', { class: 'btn btn-primary', onclick: goBack }, back),
      h('button', { class: 'btn btn-quiet', onclick: () => tabAction('keepPaused') }, t('pausedDontReopen')),
    ];
  } else if (pageState === 'over') {
    title = t('pausedOverTitle');
    lede = t('pausedOverLede', host);
    keyActions.esc = null;
    keyActions.enter = () => (originalURL ? reopen : null);
    buttons = [
      h('button', { class: 'btn btn-primary', onclick: () => tabAction('startBreak', { minutes: 10 }) }, t('pausedTakeBreak', 10)),
      reopenSite,
    ];
  } else if (pageState === 'limit') {
    const minutes = Number(fields.minutes) || 0;
    title = t('pausedLimitTitle', host);
    lede = minutes ? t('pausedLimitLedeMinutes', minutes) : t('pausedLimitLede');
    tag = minutes ? t('limitTagMinutes', minutes) : t('limitTag');
    buttons = [h('button', { class: 'btn btn-primary', onclick: goBack }, back)];
  } else {
    title = t('pausedTitle', host);
    lede = Number(fields.ends) ? t('pausedLede') : t('pausedLedeAfter');
    buttons = [
      h('button', { class: 'btn btn-primary', onclick: goBack }, back),
      h('button', { class: 'btn btn-quiet', onclick: () => tabAction('reopenLater') }, t('pausedReopenAfter')),
    ];
  }

  // The session ring while one runs; else the time left from the app's fields.
  const during = pageState === 'paused' || pageState === 'queued';
  let middle = null;
  if (during && running) {
    middle = ring(state);
  } else if (during && left !== null) {
    const big = h('div', { class: 'big num' });
    const small = h('div', { class: 'small' });
    live.push((now) => {
      const { left: l } = pausedState(now);
      big.textContent = clock(Math.max(0, l));
      small.textContent = l > 0 ? t('pausedLeftInSession') : t('pausedSessionEnding');
    });
    middle = h('div', { class: 'ring' }, h('div', { class: 'center' }, big, small));
  }

  return [
    sitePill(tag),
    h('h1', null, title),
    h('p', { class: 'lede' }, lede),
    middle,
    h('div', { class: 'actions' }, buttons),
    problemLine(),
    keys(
      keyActions.esc ? [t('keyEsc'), fields.back ? t('backToKey', fields.back) : t('backToWorkKey')] : null,
      pageState === 'over' && originalURL ? [t('keyReturn'), t('pausedKeyReopen', host)] : null,
    ),
    footer(
      h('span', null, pro ? t('pausedFooterPro')
        : t('pausedFooterFree')),
      pro ? null : h('a', { href: '#', onclick: (e) => { e.preventDefault(); tell({ type: 'openApp', page: 'upgrade' }); } }, t('pausedHowProBlocks'))),
  ];
}

// --- The session ended while the page was open ------------------------------

function overView(state) {
  const connected = snap.conn === Conn.connected && state;
  keyActions.esc = closeTab;
  keyActions.enter = () => (originalURL ? () => tell({ type: 'goTo', url: originalURL }) : null);
  return [
    sitePill(null),
    h('h1', null, connected ? t('overTitle') : t('overNotRunning')),
    h('p', { class: 'lede' }, connected ? t('overLede', host) : t('overLedeNotRunning')),
    h('div', { class: 'actions' },
      originalURL ? h('button', { class: 'btn btn-primary', onclick: () => tell({ type: 'goTo', url: originalURL }) }, t('overOpenHost', host)) : null,
      h('button', { class: 'btn btn-quiet', onclick: closeTab }, t('closeTab'))),
    keys(originalURL ? [t('keyReturn'), t('overKeyOpen', host)] : null, [t('keyEsc'), t('closeTabKey')]),
  ];
}
