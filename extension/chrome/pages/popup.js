// The toolbar popup: connection problems, today's focus and a session to
// start, the running session or break, and this page's category.

import { Conn, GET_APP_URL } from '../src/lib/protocol.js';
import { clock, displayHost, goalLabel, isWebURL, lastSeen, listSummary, minutesLabel, minutesPhrase, pagePattern, timeOfDay } from '../src/lib/format.js';
import { plural, t } from '../src/lib/i18n.js';
import { barSegments, breakClock, presetName, presetRules, sessionClock } from '../src/lib/view.js';
import { appIcon, ask, h, icons, localizePage, mount, reportAppearance, shieldIcon, siteTile, subscribe, tell } from '../src/lib/dom.js';

await localizePage();

const app = document.getElementById('app');
const SITE_ACCESS = { permissions: ['scripting'], origins: ['<all_urls>'] };
const LENGTHS = [25, 50, 90, null];
const CATEGORIES = [
  { id: 'focus', label: t('categoryFocus'), color: 'var(--indigo-fill)' },
  { id: 'neutral', label: t('categoryNeutral'), color: 'var(--grey)' },
  { id: 'distracting', label: t('categoryDistracting'), color: 'var(--orange)' },
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
    message = t('popupChangeFailed');
  }
  render();
}

async function startSession() {
  message = null;
  const reply = await ask({ type: 'startSession', minutes: length });
  if (!reply?.ok) {
    message = {
      onBreak: t('popupOnBreak'),
      alreadyRunning: t('sessionAlreadyRunning'),
    }[reply?.error] || t('popupStartFailed');
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
    options ? h('button', { class: 'icon-btn', 'aria-label': t('popupOptionsLabel'), 'data-focus-key': 'options', onclick: openOptions }, icons.sliders()) : null);
}

function links(...items) {
  return h('nav', { class: 'links', 'aria-label': t('popupMoreLabel') },
    items.map(([label, action]) => h('a', { href: '#', onclick: (e) => { e.preventDefault(); action(); } }, label)));
}

// --- Not connected ----------------------------------------------------------

function notInstalled() {
  return [
    header({ icon: shieldIcon({ color: 'var(--grey)', slashed: true }), name: 'FocusGuard', state: t('popupNotConnected'), options: false }),
    h('section', { class: 'card hero' },
      appIcon(56),
      h('h1', null, t('popupGetAppTitle')),
      h('p', null, t('popupGetAppBody')),
      h('button', { class: 'btn btn-primary btn-wide', onclick: () => { chrome.tabs.create({ url: GET_APP_URL }); window.close(); } }, t('getForMac')),
      h('div', { class: 'foot' }, t('popupFreeToDownload'))),
    h('section', { class: 'card row-card' },
      h('div', { class: 'text' },
        h('div', { class: 'title' }, t('popupAlreadyInstalled')),
        h('div', { class: 'detail' }, t('popupOpenOnce'))),
      h('button', { class: 'btn btn-quiet', onclick: () => tell({ type: 'reconnect' }) }, t('tryAgain'))),
    h('div', { class: 'footnote' }, t('popupUntilConnected')),
  ];
}

function notRunning() {
  const seen = lastSeen(snap.lastConnectedAt);
  // The setting's name goes in bold, wherever this language's sentence puts it.
  const [beforeSetting, afterSetting] = t('popupKeepRunningNote', '\n').split('\n');
  return [
    header({ icon: shieldIcon({ color: 'var(--grey)', slashed: true }), name: 'FocusGuard', state: t('popupNotConnected'), options: false }),
    h('section', { class: 'card hero' },
      appIcon(56),
      h('h1', null, t('appNotRunning')),
      h('p', null, t('popupNotRunningBody')),
      h('button', { class: 'btn btn-primary btn-wide', onclick: () => openApp() }, t('openApp')),
      seen ? h('div', { class: 'foot' }, seen) : null),
    h('section', { class: 'card note-card' },
      icons.clock(),
      h('div', null, beforeSetting, h('strong', null, t('popupOpenAtLogin')), afterSetting)),
    h('div', { class: 'center-link' },
      h('a', { href: '#', onclick: (e) => { e.preventDefault(); chrome.tabs.create({ url: GET_APP_URL }); window.close(); } }, t('popupNotOnThisMac'))),
  ];
}

function connecting() {
  return [
    header({ icon: shieldIcon({ color: 'var(--grey)' }), name: 'FocusGuard', state: t('popupConnecting'), options: false }),
    h('section', { class: 'card note-card', role: 'status' }, icons.clock(), h('div', null, t('popupLookingOnMac'))),
  ];
}

// --- Ready ------------------------------------------------------------------

function readyView(state) {
  const recap = state.phase === 'complete' && state.recap ? state.recap : null;
  const sub = recap ? t('popupConnectedRecap', recap.name, timeOfDay(recap.endedAt)) : t('popupConnectedIdle');
  const goal = state.today.goalMinutes * 60;
  const share = goal > 0 ? Math.min(1, state.today.focusSeconds / goal) : 0;
  return [
    header({ icon: recap ? shieldIcon({ solid: true, check: true, color: 'var(--indigo-fill)' }) : shieldIcon(), name: 'FocusGuard', sub }),
    h('section', { class: 'card today', 'aria-label': t('popupTodayLabel') },
      h('div', { class: 'line' },
        h('span', { class: 'big num' }, minutesLabel(state.today.focusSeconds)),
        h('span', { class: 'label' }, t('popupFocusToday')),
        h('span', { class: 'label', style: { flex: 'none' } }, t('popupGoal', goalLabel(state.today.goalMinutes)))),
      h('div', { class: 'meter', role: 'img', 'aria-label': t('popupGoalMeterLabel', minutesLabel(state.today.focusSeconds), goalLabel(state.today.goalMinutes)) },
        h('div', { style: { width: `${share * 100}%` } }))),
    pageCard(state),
    startCard(state),
    links([t('openApp'), () => openApp()], [t('todaysReport'), () => openApp('reports')]),
  ];
}

function startCard(state) {
  const blocking = !!state.plan.features?.blockInBrowser && siteAccess;
  const label = length ? t('popupStartMinutes', length) : t('popupStartOpen');
  const foot = h('div', { class: 'foot' });
  live.push((now) => {
    const ends = timeOfDay(now + length * 60000);
    foot.textContent = length
      ? (blocking ? t('popupStartEndsBlocking', ends) : t('popupStartEndsPausing', ends))
      : (blocking ? t('popupStartOpenBlocking') : t('popupStartOpenPausing'));
  });
  return h('section', { class: 'card start', 'aria-label': t('popupStartSection') },
    h('div', { class: 'section-label' }, t('popupStartSection')),
    h('div', { class: 'segmented', role: 'radiogroup', 'aria-label': t('popupLengthLabel') },
      LENGTHS.map((m) => h('button', {
        role: 'radio', 'aria-checked': String(m === length), 'data-focus-key': `len-${m}`,
        onclick: () => {
          length = m;
          try { localStorage.setItem('length', m === null ? 'none' : String(m)); } catch { /* fine */ }
          render();
        },
      }, m ? t('popupLengthMinutes', m) : t('popupLengthOpen')))),
    h('button', { class: 'btn btn-primary', onclick: startSession }, label),
    message ? h('div', { class: 'error', role: 'alert' }, message) : foot);
}

// --- This page --------------------------------------------------------------

function pageCard(state) {
  if (!page) return null;
  if (!page.web) {
    return h('section', { class: 'card page-card', 'aria-label': t('popupThisPage') },
      h('div', { class: 'section-label' }, t('popupThisPage')),
      h('div', { class: 'page-note faint', style: { fontSize: '12px' } },
        page.own ? t('popupOwnPage') : t('popupBrowserPage')));
  }
  const category = CATEGORIES.find((c) => c.id === page.category);
  const chip = category
    ? h('button', {
      class: `chip-btn chip-${category.id}`, 'aria-haspopup': 'menu', 'aria-expanded': String(menuOpen),
      'aria-label': t('popupCategoryChange', category.label), 'data-focus-key': 'chip',
      onclick: (e) => { e.stopPropagation(); menuOpen = !menuOpen; render(); },
    }, category.label, icons.chevron())
    : h('span', { class: 'faint', style: { fontSize: '12px' } }, '…');
  const onBreak = state.phase === 'break';
  return h('section', { class: 'card page-card', 'aria-label': t('popupThisPage') },
    h('div', { class: 'section-label' }, t('popupThisPage')),
    h('div', { class: 'page-row' },
      siteTile(page.host),
      h('div', { class: 'text' },
        h('div', { class: 'host' }, page.host),
        page.title ? h('div', { class: 'title' }, page.title) : null),
      chip),
    onBreak ? h('div', { class: 'note' }, t('popupBreakNoDrift')) : null,
    menuOpen && category ? categoryMenu(category.id) : null);
}

function categoryMenu(current) {
  const pageOnly = pagePattern(page.url);
  const item = (checked, label, onclick, extra = null) => h('button', {
    role: 'menuitemradio', 'aria-checked': String(checked), onclick: (e) => { e.stopPropagation(); onclick(); },
    onkeydown: menuKeys,
  }, h('span', { class: 'tick' }, checked ? icons.check() : null), extra, h('span', { style: { flex: '1 1 auto', whiteSpace: 'nowrap' } }, label));
  return h('div', { class: 'menu', role: 'menu', 'aria-label': t('popupCategoryFor', page.host) },
    CATEGORIES.map((c) => item(c.id === current, c.label, () => setCategory(c.id), icons.dot(c.color))),
    h('div', { class: 'sep', role: 'separator' }),
    h('div', { class: 'heading' }, t('popupApplyTo')),
    item(scopeChoice === 'site', t('popupApplyAllOf', page.host), () => { scopeChoice = 'site'; render(); }),
    pageOnly ? item(scopeChoice === 'page', t('popupApplyPage'), () => { scopeChoice = 'page'; render(); }) : null,
    h('div', { class: 'hint' }, t('popupApplyHint')));
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
    ? t('popupPausedSub', preset)
    : blockingOn ? t('popupFocusingBlockingSub', preset) : t('popupFocusingSub', preset);
  const c0 = sessionClock(s);
  return [
    header({
      icon: shieldIcon({ size: 24, fill: c0.progress ?? Math.min(1, c0.elapsed / 3600), color: paused ? 'var(--grey)' : 'var(--indigo-fill)' }),
      name: s.name, sub,
      badge: state.plan.tier === 'free' ? h('span', { class: 'badge badge-free' }, t('badgeFree')) : null,
    }),
    sessionClockCard(s),
    pageCard(state),
    pro ? blockedCard(state) : freeCard(state),
    pro
      ? links([t('openApp'), () => openApp()], [t('popupEditBlocked'), () => openApp('blocking')])
      : links([t('openApp'), () => openApp()], [t('todaysReport'), () => openApp('reports')]),
  ];
}

function sessionClockCard(s) {
  const big = h('span', { class: 'big num' });
  const left = h('span', { class: 'left' });
  const ends = h('span', { class: 'ends' });
  live.push((now) => {
    const c = sessionClock(s, now);
    big.textContent = clock(c.left ?? c.elapsed);
    left.textContent = c.left !== null ? (s.paused ? t('clockLeftPaused') : t('clockLeft')) : (s.paused ? t('clockSoFarPaused') : t('clockSoFar'));
    ends.textContent = c.endsAt ? t('popupEnds', timeOfDay(c.endsAt)) : (c.planned ? '' : t('popupNoEnd'));
  });
  const segments = barSegments(s);
  const c = sessionClock(s);
  const spent = [minutesPhrase(c.elapsed), minutesPhrase(s.focusSeconds), minutesPhrase(s.driftSeconds), minutesPhrase(s.otherSeconds)];
  const barLabel = c.planned ? t('popupBarPlanned', Math.round(c.planned / 60), ...spent) : t('popupBarOpen', ...spent);
  return h('section', { class: 'card clock-card', 'aria-label': t('popupSessionLabel') },
    h('div', { class: 'line' }, big, left, ends),
    h('div', { class: 'bar', role: 'img', 'aria-label': barLabel },
      segments.map((seg) => h('div', { class: seg.kind, style: { width: `${seg.pct}%` } }))),
    h('div', { class: 'legend' },
      h('span', null, h('span', { class: 'swatch swatch-f' }), t('popupLegendFocus', minutesLabel(s.focusSeconds))),
      h('span', null, h('span', { class: 'swatch swatch-d' }), t('popupLegendDrift', minutesLabel(s.driftSeconds))),
      h('span', null, h('span', { class: 'swatch swatch-o' }), t('popupLegendOther', minutesLabel(s.otherSeconds)))));
}

function ruleLine(state) {
  const rules = presetRules(state.policy);
  const name = presetName(state.preset);
  if (!rules.pass) {
    return state.blocking.lockedUntil
      ? t('popupRuleNobodyUntil', name, timeOfDay(state.blocking.lockedUntil))
      : t('popupRuleNobodySession', name);
  }
  const length = minutesPhrase(rules.passSeconds);
  return rules.passWait > 0
    ? t('popupRuleWait', name, rules.passWait, length)
    : t('popupRuleNow', name, length);
}

function blockedCard(state) {
  const b = state.blocking;
  if (!siteAccess) {
    return h('section', { class: 'card plan-card', 'aria-label': t('popupBlockingLabel') },
      h('div', { class: 'item' },
        h('div', { class: 'item-top' }, icons.lock(), h('span', { class: 'name grow' }, t('blockBeforeLoad'))),
        h('div', { class: 'desc' }, t('popupSiteAccessBody'))),
      h('button', { class: 'btn btn-primary', onclick: allowSiteAccess }, t('popupAllowSiteAccess')));
  }
  const visits = state.session.stoppedVisits;
  return h('section', { class: 'card blocked', 'aria-label': t('popupBlockedThisSession') },
    h('div', { class: 'top' },
      h('div', { class: 'section-label' }, t('popupBlockedThisSession')),
      visits > 0 ? h('span', { class: 'count num' }, plural('popupStoppedVisits', visits)) : null),
    b.sites.length ? h('div', { class: 'group' },
      h('div', { class: 'group-label' }, t('popupWholeSites')),
      h('div', { class: 'pills' }, b.sites.map((s) => h('span', null, s)))) : null,
    b.parts.length && state.plan.features?.partsOfSites ? h('div', { class: 'group' },
      h('div', { class: 'group-label' }, t('popupPartsOfSites')),
      h('div', { class: 'pills' }, b.parts.map((s) => h('span', null, s)))) : null,
    !b.sites.length && !b.parts.length ? h('div', { class: 'rule' }, t('popupNothingBlocked')) : null,
    h('div', { class: 'rule' }, ruleLine(state)));
}

function freeCard(state) {
  const pause = state.blocking.pauseTab;
  return h('section', { class: 'card plan-card', 'aria-label': t('popupBlockingLabel') },
    h('div', { class: 'item' },
      h('div', { class: 'item-top' },
        h('span', { style: { color: 'var(--indigo-ink)', display: 'flex' } }, icons.tabPause()),
        h('span', { class: 'name grow' }, t('popupPauseTab')),
        h('span', { class: 'value' }, pause ? t('popupPauseOn') : t('popupPauseOff'))),
      h('div', { class: 'desc' }, t('popupPauseTabBody'))),
    snap.settings?.hideProCard ? null : [
      h('div', { class: 'sep' }),
      h('div', { class: 'item', style: { gap: '6px' } },
        h('div', { class: 'item-top' },
          h('span', { style: { color: 'var(--ink-2)', display: 'flex' } }, icons.lock()),
          h('span', { class: 'name' }, t('blockBeforeLoad')),
          h('span', { class: 'badge badge-pro' }, t('badgePro')),
          h('span', { class: 'grow' }),
          h('button', { class: 'hide-btn', onclick: () => tell({ type: 'setSetting', key: 'hideProCard', value: true }) }, t('popupHide'))),
        h('div', { class: 'list' },
          h('span', null, t('proNeverOpen')),
          h('span', null, t('popupProParts')),
          h('span', null, t('proYoutube')),
          h('span', null, t('proLimits'))),
        h('a', { class: 'more', href: '#', onclick: (e) => { e.preventDefault(); openApp('upgrade'); } }, t('proTrial'))),
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
    back.textContent = t('popupBackAt', timeOfDay(info.endsAt));
    fill.style.width = `${c.progress * 100}%`;
  });
  const blocked = [...state.blocking.sites, ...state.blocking.parts];
  const pausedText = state.plan.features?.blockInBrowser && blocked.length
    ? plural('popupBreakSitesOpen', blocked.length, listSummary(blocked))
    : t('popupTabsWontPause');
  return [
    header({ icon: h('span', { style: { color: 'var(--indigo-fill)', display: 'flex' } }, icons.cup({ size: 24 })), name: t('popupBreakTitle'), sub: info.after ? t('popupBreakAfter', info.after) : null }),
    h('section', { class: 'card clock-card', 'aria-label': t('popupBreakTitle') },
      h('div', { class: 'line' }, big, h('span', { class: 'left' }, t('clockLeft')), back),
      h('div', { class: 'bar', role: 'img', 'aria-label': t('popupBreakBarLabel', Math.round(info.plannedSeconds / 60)) }, fill),
      h('div', { class: 'tip' }, t('popupBreakTip'))),
    pageCard(state),
    h('section', { class: 'card paused-card' },
      icons.pauseBars(),
      h('div', null,
        h('div', { class: 'title' }, t('popupBlockingPaused')),
        h('div', { class: 'detail' }, pausedText))),
    h('div', { class: 'pair' },
      h('button', { class: 'btn btn-quiet', onclick: () => ask({ type: 'extendBreak', minutes: 5 }) }, t('popupExtendBreak')),
      h('button', {
        class: 'btn btn-quiet', disabled: !info.canEndEarly,
        title: info.canEndEarly ? null : t('popupBreaksRunToEnd'),
        onclick: () => ask({ type: 'endBreak' }),
      }, t('popupEndBreak'))),
    message ? h('div', { class: 'error', role: 'alert' }, message) : null,
    links([t('openApp'), () => openApp()], [t('todaysReport'), () => openApp('reports')]),
  ];
}
