// The toolbar popup: connection problems, today's focus and a session to
// start, the running session or break, and this page's category.

import { Conn, GET_APP_URL } from '../src/lib/protocol.js';
import { clock, displayHost, goalLabel, isWebURL, lastSeen, listSummary, minutesLabel, pagePattern, timeOfDay } from '../src/lib/format.js';
import { barSegments, breakClock, presetName, presetRules, sessionClock } from '../src/lib/view.js';
import { appIcon, ask, h, icons, mount, reportAppearance, shieldIcon, siteTile, subscribe, tell } from '../src/lib/dom.js';

const app = document.getElementById('app');
const SITE_ACCESS = { permissions: ['scripting'], origins: ['<all_urls>'] };
const LENGTHS = [25, 50, 90, null];
const CATEGORIES = [
  { id: 'focus', label: 'Focus', color: 'var(--indigo-fill)' },
  { id: 'neutral', label: 'Neutral', color: 'var(--grey)' },
  { id: 'distracting', label: 'Distracting', color: 'var(--orange)' },
];

let snap = null;
let page = null;          // the tab in this window and its category
let menuOpen = false;
let scopeChoice = 'site';
let length = 50;
let message = null;       // a one-line answer to the last action
let siteAccess = false;
let renderedKey = '';
let live = [];            // per-second updaters for the current view

try {
  const saved = localStorage.getItem('length');
  if (saved !== null) length = saved === 'none' ? null : Number(saved) || 50;
} catch { /* storage can be off; keep the default */ }

reportAppearance();
subscribe('popup', (next) => {
  const wasConnected = snap?.conn === Conn.connected;
  snap = next;
  if (!wasConnected && snap.conn === Conn.connected) loadPage();
  render();
});
chrome.permissions.contains(SITE_ACCESS).then((value) => { siteAccess = value; render(); });
setInterval(() => live.forEach((update) => update(Date.now())), 1000);
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && menuOpen) {
    event.preventDefault();
    closeMenu(true);
  }
});
document.addEventListener('click', (event) => {
  if (menuOpen && !event.target.closest('.menu, .chip-btn')) closeMenu(false);
});

// ---------------------------------------------------------------------------

async function loadPage() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return;
  const url = tab.url || '';
  const own = url.startsWith(chrome.runtime.getURL(''));
  page = { tab, url, own, web: isWebURL(url), host: displayHost(url), title: tab.title || '' };
  render();
  if (!page.web) return;
  const reply = await ask({ type: 'classify', url });
  if (reply?.ok && reply.result) {
    page = { ...page, category: reply.result.category, ruleScope: reply.result.ruleScope };
    scopeChoice = page.ruleScope || 'site';
    render();
  }
}

async function setCategory(category) {
  if (!page?.web) return;
  const previous = page.category;
  page = { ...page, category };
  closeMenu(true);
  const reply = await ask({ type: 'setCategory', url: page.url, scope: scopeChoice, category });
  if (reply?.ok && reply.result) {
    page = { ...page, category: reply.result.category, ruleScope: reply.result.ruleScope };
  } else {
    page = { ...page, category: previous };
    message = "Couldn't change it. Is FocusGuard still open?";
  }
  render();
}

async function startSession() {
  message = null;
  const reply = await ask({ type: 'startSession', minutes: length });
  if (!reply?.ok) {
    message = {
      onBreak: 'Finish the break first.',
      alreadyRunning: 'A session is already running.',
    }[reply?.error] || "Couldn't start it. Is FocusGuard still open?";
    render();
  }
}

function openApp(pageName) {
  tell({ type: 'openApp', page: pageName || null });
  window.close();
}

function openOptions() {
  chrome.runtime.openOptionsPage();
  window.close();
}

function closeMenu(returnFocus) {
  menuOpen = false;
  render();
  if (returnFocus) document.querySelector('.chip-btn')?.focus();
}

async function allowSiteAccess() {
  const granted = await chrome.permissions.request(SITE_ACCESS).catch(() => false);
  siteAccess = granted;
  if (granted) await tell({ type: 'requestSiteAccess' });
  render();
}

// ---------------------------------------------------------------------------
// Rendering: rebuild when what's shown changes, tick the clocks in between.

function render() {
  if (!snap) return;
  const state = snap.state;
  const key = JSON.stringify({
    conn: snap.conn, phase: state?.phase, plan: state?.plan, session: state?.session && {
      name: state.session.name, paused: state.session.paused,
      planned: state.session.plannedMinutes, visits: state.session.stoppedVisits,
      segments: state.session.segments, f: state.session.focusSeconds, d: state.session.driftSeconds, o: state.session.otherSeconds,
    },
    preset: state?.preset, policy: state?.policy, brk: state?.break, recap: state?.recap, blocking: state?.blocking, today: state?.today,
    page, menuOpen, scopeChoice, length, message, siteAccess,
    hideProCard: snap.settings?.hideProCard, appPath: snap.appPath, last: snap.lastConnectedAt,
  });
  if (key === renderedKey) return;
  const focused = document.activeElement?.dataset?.focusKey;
  renderedKey = key;
  live = [];
  mount(app, view());
  if (focused) app.querySelector(`[data-focus-key="${focused}"]`)?.focus();
  if (menuOpen) app.querySelector('.menu [aria-checked="true"]')?.focus();
  live.forEach((update) => update(Date.now()));
}

function view() {
  switch (snap.conn) {
    case Conn.notInstalled: return notInstalled();
    case Conn.notRunning: return notRunning();
    case Conn.connected: break;
    default: return connecting();
  }
  const state = snap.state;
  if (!state) return connecting();
  switch (state.phase) {
    case 'focusing':
    case 'paused': return sessionView(state);
    case 'break': return breakView(state);
    default: return readyView(state);
  }
}

function header({ icon, name, sub, state, badge, options = true }) {
  return h('header', { class: 'header' },
    icon,
    h('div', { class: 'titles' },
      h('div', { class: 'name' }, name),
      sub ? h('div', { class: 'sub' }, sub) : null),
    state ? h('span', { class: 'state' }, state) : null,
    badge,
    options ? h('button', { class: 'icon-btn', 'aria-label': 'Options', 'data-focus-key': 'options', onclick: openOptions }, icons.sliders()) : null);
}

function links(...items) {
  return h('nav', { class: 'links', 'aria-label': 'More' },
    items.map(([label, action]) => h('a', { href: '#', onclick: (e) => { e.preventDefault(); action(); } }, label)));
}

// --- Not connected ----------------------------------------------------------

function notInstalled() {
  return [
    header({ icon: shieldIcon({ color: 'var(--grey)', slashed: true }), name: 'FocusGuard', state: 'Not connected', options: false }),
    h('section', { class: 'card hero' },
      appIcon(56),
      h('h1', null, 'Get the FocusGuard app'),
      h('p', null, "This extension works with FocusGuard for Mac. The app runs your sessions; the extension tells it which page you're on and pauses distracting tabs while you focus."),
      h('button', { class: 'btn btn-primary btn-wide', onclick: () => { chrome.tabs.create({ url: GET_APP_URL }); window.close(); } }, 'Get FocusGuard for Mac'),
      h('div', { class: 'foot' }, 'Free to download · needs macOS 26')),
    h('section', { class: 'card row-card' },
      h('div', { class: 'text' },
        h('div', { class: 'title' }, 'Already installed it?'),
        h('div', { class: 'detail' }, 'Open FocusGuard once, then try again.')),
      h('button', { class: 'btn btn-quiet', onclick: () => tell({ type: 'reconnect' }) }, 'Try again')),
    h('div', { class: 'footnote' }, 'Until the app is connected, nothing in this browser is tracked or paused.'),
  ];
}

function notRunning() {
  const seen = lastSeen(snap.lastConnectedAt);
  return [
    header({ icon: shieldIcon({ color: 'var(--grey)', slashed: true }), name: 'FocusGuard', state: 'Not connected', options: false }),
    h('section', { class: 'card hero' },
      appIcon(56),
      h('h1', null, "FocusGuard isn't running"),
      h('p', null, 'Open it to count your time in this browser and keep distracting sites out of your sessions.'),
      h('button', { class: 'btn btn-primary btn-wide', onclick: () => openApp() }, 'Open FocusGuard'),
      seen ? h('div', { class: 'foot' }, `Last connected ${seen}`) : null),
    h('section', { class: 'card note-card' },
      icons.clock(),
      h('div', null, "While it's closed, nothing here is tracked or paused. To keep it running, turn on ",
        h('strong', null, 'Open at login'), " in FocusGuard's settings.")),
    h('div', { class: 'center-link' },
      h('a', { href: '#', onclick: (e) => { e.preventDefault(); chrome.tabs.create({ url: GET_APP_URL }); window.close(); } }, 'Not on this Mac? Get FocusGuard')),
  ];
}

function connecting() {
  return [
    header({ icon: shieldIcon({ color: 'var(--grey)' }), name: 'FocusGuard', state: 'Connecting…', options: false }),
    h('section', { class: 'card note-card', role: 'status' }, icons.clock(), h('div', null, 'Looking for FocusGuard on this Mac…')),
  ];
}

// --- Ready ------------------------------------------------------------------

function readyView(state) {
  const recap = state.phase === 'complete' && state.recap ? state.recap : null;
  const sub = recap ? `Connected · ${recap.name} ended at ${timeOfDay(recap.endedAt)}` : 'Connected · no session running';
  const goal = state.today.goalMinutes * 60;
  const share = goal > 0 ? Math.min(1, state.today.focusSeconds / goal) : 0;
  return [
    header({ icon: recap ? shieldIcon({ solid: true, check: true, color: 'var(--indigo-fill)' }) : shieldIcon(), name: 'FocusGuard', sub }),
    h('section', { class: 'card today', 'aria-label': 'Today' },
      h('div', { class: 'line' },
        h('span', { class: 'big num' }, minutesLabel(state.today.focusSeconds)),
        h('span', { class: 'label' }, 'focus today'),
        h('span', { class: 'label', style: { flex: 'none' } }, `Goal ${goalLabel(state.today.goalMinutes)}`)),
      h('div', { class: 'meter', role: 'img', 'aria-label': `${minutesLabel(state.today.focusSeconds)} of a ${goalLabel(state.today.goalMinutes)} goal` },
        h('div', { style: { width: `${share * 100}%` } }))),
    pageCard(state),
    startCard(state),
    links(['Open FocusGuard', () => openApp()], ["Today's report", () => openApp('reports')]),
  ];
}

function startCard(state) {
  const blocking = !!state.plan.features?.blockInBrowser && siteAccess;
  const label = length ? `Start ${length}-minute session` : 'Start a session with no end';
  const foot = h('div', { class: 'foot' });
  live.push((now) => {
    const ends = length ? `Ends at ${timeOfDay(now + length * 60000)}. ` : 'No set end. ';
    foot.textContent = ends + (blocking ? 'Blocking turns on when it starts.' : 'Distracting tabs pause if you drift.');
  });
  return h('section', { class: 'card start', 'aria-label': 'Start a session' },
    h('div', { class: 'section-label' }, 'Start a session'),
    h('div', { class: 'segmented', role: 'radiogroup', 'aria-label': 'Length' },
      LENGTHS.map((m) => h('button', {
        role: 'radio', 'aria-checked': String(m === length), 'data-focus-key': `len-${m}`,
        onclick: () => {
          length = m;
          try { localStorage.setItem('length', m === null ? 'none' : String(m)); } catch { /* fine */ }
          render();
        },
      }, m ? `${m} min` : 'No end'))),
    h('button', { class: 'btn btn-primary', onclick: startSession }, label),
    message ? h('div', { class: 'error', role: 'alert' }, message) : foot);
}

// --- This page --------------------------------------------------------------

function pageCard(state) {
  if (!page) return null;
  if (!page.web) {
    return h('section', { class: 'card page-card', 'aria-label': 'This page' },
      h('div', { class: 'section-label' }, 'This page'),
      h('div', { class: 'page-note faint', style: { fontSize: '12px' } },
        page.own ? 'A FocusGuard page. Time here isn\'t counted as drift.' : "Browser pages aren't sorted."));
  }
  const category = CATEGORIES.find((c) => c.id === page.category);
  const chip = category
    ? h('button', {
      class: `chip-btn chip-${category.id}`, 'aria-haspopup': 'menu', 'aria-expanded': String(menuOpen),
      'aria-label': `Category: ${category.label}. Change`, 'data-focus-key': 'chip',
      onclick: (e) => { e.stopPropagation(); menuOpen = !menuOpen; render(); },
    }, category.label, icons.chevron())
    : h('span', { class: 'faint', style: { fontSize: '12px' } }, '…');
  const onBreak = state.phase === 'break';
  return h('section', { class: 'card page-card', 'aria-label': 'This page' },
    h('div', { class: 'section-label' }, 'This page'),
    h('div', { class: 'page-row' },
      siteTile(page.host),
      h('div', { class: 'text' },
        h('div', { class: 'host' }, page.host),
        page.title ? h('div', { class: 'title' }, page.title) : null),
      chip),
    onBreak ? h('div', { class: 'note' }, "Breaks don't count as drift.") : null,
    menuOpen && category ? categoryMenu(category.id) : null);
}

function categoryMenu(current) {
  const pageOnly = pagePattern(page.url);
  const item = (checked, label, onclick, extra = null) => h('button', {
    role: 'menuitemradio', 'aria-checked': String(checked), onclick: (e) => { e.stopPropagation(); onclick(); },
    onkeydown: menuKeys,
  }, h('span', { class: 'tick' }, checked ? icons.check() : null), extra, h('span', { style: { flex: '1 1 auto', whiteSpace: 'nowrap' } }, label));
  return h('div', { class: 'menu', role: 'menu', 'aria-label': `Category for ${page.host}` },
    CATEGORIES.map((c) => item(c.id === current, c.label, () => setCategory(c.id), icons.dot(c.color))),
    h('div', { class: 'sep', role: 'separator' }),
    h('div', { class: 'heading' }, 'Apply to'),
    item(scopeChoice === 'site', `All of ${page.host}`, () => { scopeChoice = 'site'; render(); }),
    pageOnly ? item(scopeChoice === 'page', 'Only this page', () => { scopeChoice = 'page'; render(); }) : null,
    h('div', { class: 'hint' }, 'Also changes time already counted today.'));
}

function menuKeys(event) {
  const items = [...document.querySelectorAll('.menu button')];
  const at = items.indexOf(event.currentTarget);
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    const next = (at + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    items[next].focus();
  }
}

// --- Session ----------------------------------------------------------------

function sessionView(state) {
  const s = state.session;
  const paused = state.phase === 'paused';
  const pro = !!state.plan.features?.blockInBrowser;
  const blockingOn = pro && siteAccess && !paused;
  const preset = presetName(state.preset);
  const sub = paused
    ? `Paused · ${preset}`
    : blockingOn ? `Focusing · blocking is on · ${preset}` : `Focusing · ${preset}`;
  const c0 = sessionClock(s);
  return [
    header({
      icon: shieldIcon({ size: 24, fill: c0.progress ?? Math.min(1, c0.elapsed / 3600), color: paused ? 'var(--grey)' : 'var(--indigo-fill)' }),
      name: s.name, sub,
      badge: state.plan.tier === 'free' ? h('span', { class: 'badge badge-free' }, 'FREE') : null,
    }),
    sessionClockCard(s),
    pageCard(state),
    pro ? blockedCard(state) : freeCard(state),
    pro
      ? links(['Open FocusGuard', () => openApp()], ['Edit blocked sites', () => openApp('blocking')])
      : links(['Open FocusGuard', () => openApp()], ["Today's report", () => openApp('reports')]),
  ];
}

function sessionClockCard(s) {
  const big = h('span', { class: 'big num' });
  const left = h('span', { class: 'left' });
  const ends = h('span', { class: 'ends' });
  live.push((now) => {
    const c = sessionClock(s, now);
    big.textContent = clock(c.left ?? c.elapsed);
    left.textContent = c.left !== null ? (s.paused ? 'left · paused' : 'left') : (s.paused ? 'so far · paused' : 'so far');
    ends.textContent = c.endsAt ? `ends ${timeOfDay(c.endsAt)}` : (c.planned ? '' : 'no end');
  });
  const segments = barSegments(s);
  const c = sessionClock(s);
  const minutes = (sec) => `${Math.round(sec / 60)} ${Math.round(sec / 60) === 1 ? 'minute' : 'minutes'}`;
  const barLabel = `${c.planned ? `${Math.round(c.planned / 60)}-minute session, ` : ''}${minutes(c.elapsed)} in: `
    + `${minutes(s.focusSeconds)} focus, ${minutes(s.driftSeconds)} drift, ${minutes(s.otherSeconds)} other`;
  return h('section', { class: 'card clock-card', 'aria-label': 'Session' },
    h('div', { class: 'line' }, big, left, ends),
    h('div', { class: 'bar', role: 'img', 'aria-label': barLabel },
      segments.map((seg) => h('div', { class: seg.kind, style: { width: `${seg.pct}%` } }))),
    h('div', { class: 'legend' },
      h('span', null, h('span', { class: 'swatch swatch-f' }), `${minutesLabel(s.focusSeconds)} focus`),
      h('span', null, h('span', { class: 'swatch swatch-d' }), `${minutesLabel(s.driftSeconds)} drift`),
      h('span', null, h('span', { class: 'swatch swatch-o' }), `${minutesLabel(s.otherSeconds)} other`)));
}

function ruleLine(state) {
  const rules = presetRules(state.policy);
  const name = presetName(state.preset);
  if (!rules.pass) {
    const until = state.blocking.lockedUntil ? ` until ${timeOfDay(state.blocking.lockedUntil)}` : ' until the session ends';
    return `These pages don't load. ${name} lets nobody through${until}.`;
  }
  const length = minutesLabel(rules.passSeconds).replace(/m$/, ' minutes').replace(/^1 minutes$/, '1 minute');
  return rules.passWait > 0
    ? `These pages don't load. ${name} lets you through after a ${rules.passWait}-second wait, for ${length}.`
    : `These pages don't load. ${name} lets you through right away, for ${length}.`;
}

function blockedCard(state) {
  const b = state.blocking;
  if (!siteAccess) {
    return h('section', { class: 'card plan-card', 'aria-label': 'Blocking' },
      h('div', { class: 'item' },
        h('div', { class: 'item-top' }, icons.lock(), h('span', { class: 'name grow' }, 'Block before pages load')),
        h('div', { class: 'desc' }, 'FocusGuard needs access to sites to keep distracting pages from loading. It still never reads what\'s on them.')),
      h('button', { class: 'btn btn-primary', onclick: allowSiteAccess }, 'Allow site access'));
  }
  const visits = state.session.stoppedVisits;
  return h('section', { class: 'card blocked', 'aria-label': 'Blocked this session' },
    h('div', { class: 'top' },
      h('div', { class: 'section-label' }, 'Blocked this session'),
      visits > 0 ? h('span', { class: 'count num' }, `stopped ${visits} ${visits === 1 ? 'visit' : 'visits'}`) : null),
    b.sites.length ? h('div', { class: 'group' },
      h('div', { class: 'group-label' }, 'Whole sites'),
      h('div', { class: 'pills' }, b.sites.map((s) => h('span', null, s)))) : null,
    b.parts.length && state.plan.features?.partsOfSites ? h('div', { class: 'group' },
      h('div', { class: 'group-label' }, 'Parts of sites'),
      h('div', { class: 'pills' }, b.parts.map((s) => h('span', null, s)))) : null,
    !b.sites.length && !b.parts.length ? h('div', { class: 'rule' }, 'Nothing is blocked yet. Mark sites Distracting to block them during sessions.') : null,
    h('div', { class: 'rule' }, ruleLine(state)));
}

function freeCard(state) {
  const pause = state.blocking.pauseTab;
  return h('section', { class: 'card plan-card', 'aria-label': 'Blocking' },
    h('div', { class: 'item' },
      h('div', { class: 'item-top' },
        h('span', { style: { color: 'var(--indigo-ink)', display: 'flex' } }, icons.tabPause()),
        h('span', { class: 'name grow' }, 'Pause the tab'),
        h('span', { class: 'value' }, pause ? 'On' : 'Off')),
      h('div', { class: 'desc' }, 'If you stay on a distracting site, the block screen shows on your Mac and this tab switches to a calm page.')),
    snap.settings?.hideProCard ? null : [
      h('div', { class: 'sep' }),
      h('div', { class: 'item', style: { gap: '6px' } },
        h('div', { class: 'item-top' },
          h('span', { style: { color: 'var(--ink-2)', display: 'flex' } }, icons.lock()),
          h('span', { class: 'name' }, 'Block before pages load'),
          h('span', { class: 'badge badge-pro' }, 'PRO'),
          h('span', { class: 'grow' }),
          h('button', { class: 'hide-btn', onclick: () => tell({ type: 'setSetting', key: 'hideProCard', value: true }) }, 'Hide')),
        h('div', { class: 'list' },
          h('span', null, 'Distracting pages never open'),
          h('span', null, 'Parts of sites, like youtube.com/shorts'),
          h('span', null, 'YouTube sorted video by video'),
          h('span', null, 'Daily limits on as many sites as you like')),
        h('a', { class: 'more', href: '#', onclick: (e) => { e.preventDefault(); openApp('upgrade'); } }, 'See Pro, free for 14 days')),
    ]);
}

// --- Break ------------------------------------------------------------------

function breakView(state) {
  const info = state.break;
  const big = h('span', { class: 'big num' });
  const back = h('span', { class: 'ends' });
  const fill = h('div', { class: 'brk' });
  live.push((now) => {
    const c = breakClock(info, now);
    big.textContent = clock(c.left);
    back.textContent = `back at ${timeOfDay(info.endsAt)}`;
    fill.style.width = `${c.progress * 100}%`;
  });
  const blocked = [...state.blocking.sites, ...state.blocking.parts];
  const pausedText = state.plan.features?.blockInBrowser && blocked.length
    ? `${listSummary(blocked)} open normally until the break ends.`
    : 'Tabs won\'t pause until the break ends.';
  return [
    header({ icon: h('span', { style: { color: 'var(--indigo-fill)', display: 'flex' } }, icons.cup({ size: 24 })), name: 'Break', sub: info.after ? `After ${info.after}` : null }),
    h('section', { class: 'card clock-card', 'aria-label': 'Break' },
      h('div', { class: 'line' }, big, h('span', { class: 'left' }, 'left'), back),
      h('div', { class: 'bar', role: 'img', 'aria-label': `${Math.round(info.plannedSeconds / 60)}-minute break` }, fill),
      h('div', { class: 'tip' }, 'Stand up, refill your water, look at something far away.')),
    pageCard(state),
    h('section', { class: 'card paused-card' },
      icons.pauseBars(),
      h('div', null,
        h('div', { class: 'title' }, 'Blocking is paused'),
        h('div', { class: 'detail' }, pausedText))),
    h('div', { class: 'pair' },
      h('button', { class: 'btn btn-quiet', onclick: () => ask({ type: 'extendBreak', minutes: 5 }) }, '+5 minutes'),
      h('button', {
        class: 'btn btn-quiet', disabled: !info.canEndEarly,
        title: info.canEndEarly ? null : 'Breaks run to the end (Settings › Sessions)',
        onclick: () => ask({ type: 'endBreak' }),
      }, 'End break')),
    message ? h('div', { class: 'error', role: 'alert' }, message) : null,
    links(['Open FocusGuard', () => openApp()], ["Today's report", () => openApp('reports')]),
  ];
}
