// First run: welcome, connect to the app, pin the button, done. Opens once,
// right after the extension is added.

import { Conn, GET_APP_URL } from '../src/lib/protocol.js';
import { appIcon, ask, h, icons, mount, reportAppearance, shieldIcon, subscribe, tell } from '../src/lib/dom.js';

const app = document.getElementById('app');
const SITE_ACCESS = { permissions: ['scripting'], origins: ['<all_urls>'] };

let snap = null;
let step = 'welcome';
let pinned = false;
let skippedPin = false;
let incognito = false;
let siteAccess = false;
let started = null;
let renderedKey = '';

reportAppearance();
subscribe('welcome', (next) => {
  snap = next;
  if (step === 'connect' && snap.conn === Conn.connected) step = pinned ? 'done' : 'pin';
  render();
});
refresh();
setInterval(refresh, 1000);

async function refresh() {
  const settings = await chrome.action.getUserSettings?.().catch(() => null);
  pinned = !!settings?.isOnToolbar;
  incognito = await chrome.extension.isAllowedIncognitoAccess();
  siteAccess = await chrome.permissions.contains(SITE_ACCESS);
  if (step === 'pin' && pinned) step = 'done';
  render();
}

function go(next) {
  step = next;
  if (step === 'connect' && snap?.conn === Conn.connected) step = pinned ? 'done' : 'pin';
  render();
  window.scrollTo(0, 0);
}

function render() {
  const key = JSON.stringify({ step, conn: snap?.conn, plan: snap?.state?.plan, version: snap?.state?.app?.version, pinned, skippedPin, incognito, siteAccess, started });
  if (key === renderedKey) return;
  renderedKey = key;
  const views = { welcome, connect, pin, done };
  mount(app, views[step]());
  app.querySelector('[data-autofocus]')?.focus();
}

function stepper(current) {
  const order = ['connect', 'pin', 'done'];
  const names = { connect: 'Connect', pin: 'Pin', done: 'Done' };
  const at = order.indexOf(current);
  const items = [];
  order.forEach((id, i) => {
    if (i > 0) items.push(h('li', { class: 'rule', 'aria-hidden': 'true' }));
    const isDone = i < at || (id === 'done' && current === 'done');
    items.push(h('li', { 'aria-current': id === current ? 'step' : null },
      h('span', { class: `n${isDone && id !== current ? ' done' : ''}` }, isDone && id !== current ? icons.check({ size: 12 }) : String(i + 1)),
      h('span', null, names[id])));
  });
  return h('ol', { class: 'steps', 'aria-label': 'Setup steps' }, items);
}

// --- 1. Welcome -------------------------------------------------------------

function welcome() {
  const feature = (glyph, badge, name, text) => h('div', { class: 'feature' },
    h('div', { class: 'top' }, h('div', { class: 'glyph', 'aria-hidden': 'true' }, glyph), h('span', { class: 'grow' }), badge),
    h('div', { class: 'name' }, name),
    h('div', { class: 'text' }, text));
  return [
    h('div', { class: 'hero-icon', 'aria-hidden': 'true' }, appIcon(88).firstChild),
    h('h1', null, 'FocusGuard is in your browser.'),
    h('p', { class: 'lede' }, 'It works with the FocusGuard app on your Mac. Setting it up takes about a minute.'),
    h('div', { class: 'features' },
      feature(icons.clock(), h('span', { class: 'badge badge-free' }, 'FREE'), 'Your time, site by site',
        "It sees which page you're on, so a code review and a YouTube rabbit hole don't count the same."),
      feature(icons.lock(), h('span', { class: 'badge badge-pro' }, 'PRO'), 'Blocks before pages load',
        'Distracting sites, and parts of sites like YouTube Shorts, stay closed during sessions.'),
      feature(shieldIcon({ size: 16, color: 'currentColor' }), null, 'Stays on your Mac',
        "Page addresses and titles go straight to the app. There's no FocusGuard server.")),
    h('button', { class: 'btn btn-primary big-btn', 'data-autofocus': true, onclick: () => go('connect') }, 'Set up'),
    h('div', { class: 'next' }, 'Next: connect to the app, then pin the button'),
  ];
}

// --- 2. Connect -------------------------------------------------------------

function connect() {
  const conn = snap?.conn;
  const missing = conn === Conn.notInstalled;
  const head = missing
    ? h('div', { class: 'head' },
      appIcon(52),
      h('div', { class: 'text' },
        h('div', { class: 'title' }, "FocusGuard isn't on this Mac yet"),
        h('div', { class: 'detail' }, 'Install it and open it once. This page moves on by itself.')),
      h('button', { class: 'btn btn-primary', 'data-autofocus': true, onclick: () => chrome.tabs.create({ url: GET_APP_URL }) }, 'Get FocusGuard for Mac'))
    : h('div', { class: 'head' },
      appIcon(52),
      h('div', { class: 'text' },
        h('div', { class: 'title' }, conn === Conn.notRunning ? "FocusGuard is on this Mac, but it isn't open" : 'Looking for FocusGuard'),
        h('div', { class: 'detail' }, 'Open it and this page moves on by itself.')),
      h('button', { class: 'btn btn-primary', 'data-autofocus': true, onclick: () => tell({ type: 'openApp' }) }, 'Open FocusGuard'));
  return [
    stepper('connect'),
    h('h1', null, 'Connect to FocusGuard'),
    h('p', { class: 'lede' }, 'The extension needs the app running on this Mac.'),
    h('section', { class: 'panel', 'aria-label': 'FocusGuard app' },
      head,
      h('div', { class: 'status', role: 'status' },
        h('span', { class: 'spinner', 'aria-hidden': 'true' }),
        h('span', null, 'Looking for FocusGuard…'),
        h('a', { href: '#', onclick: (e) => { e.preventDefault(); tell({ type: 'reconnect' }); } }, 'Try again'))),
    missing ? null : h('section', { class: 'quiet-panel', 'aria-label': 'Get FocusGuard' },
      h('div', { class: 'text' },
        h('div', { class: 'title' }, "Don't have FocusGuard yet?"),
        h('div', { class: 'detail' }, 'Free to download for Mac, needs macOS 26.')),
      h('button', { class: 'btn btn-quiet', onclick: () => chrome.tabs.create({ url: GET_APP_URL }) }, 'Get FocusGuard for Mac')),
    h('div', { class: 'small-print' }, "The extension and the app talk through your browser's native messaging, on this Mac only."),
  ];
}

// --- 3. Pin -----------------------------------------------------------------

function pin() {
  return [
    stepper('pin'),
    h('h1', null, 'Pin FocusGuard to the toolbar'),
    h('p', { class: 'lede' }, "Then the time left and what's blocked are one click away."),
    h('section', { class: 'panel how', 'aria-label': 'How to pin' },
      h('div', { class: 'step' },
        h('span', { class: 'num', 'aria-hidden': 'true' }, '1'),
        h('div', null,
          h('div', { class: 'title' }, 'Click the Extensions button'),
          h('div', { class: 'detail' }, 'The puzzle piece next to the address bar, top right.'))),
      h('div', { class: 'step' },
        h('span', { class: 'num', 'aria-hidden': 'true' }, '2'),
        h('div', null,
          h('div', { class: 'title' }, 'Click the pin next to FocusGuard'),
          h('div', { class: 'detail' }, 'The shield appears beside the address bar and this page moves on.'))),
      h('div', { class: 'status', role: 'status' },
        h('span', { class: 'spinner', 'aria-hidden': 'true' }),
        h('span', null, 'Waiting for the pin…'),
        h('a', { href: '#', 'data-autofocus': true, onclick: (e) => { e.preventDefault(); skippedPin = true; go('done'); } }, 'Skip for now'))),
    h('div', { class: 'small-print' }, "Can't see a puzzle piece? Some browsers keep extensions in their main menu instead."),
  ];
}

// --- 4. Done ----------------------------------------------------------------

async function closeThisTab() {
  const tab = await chrome.tabs.getCurrent();
  if (tab?.id != null) chrome.tabs.remove(tab.id);
}

async function startFifty() {
  const reply = await ask({ type: 'startSession', minutes: 50 });
  started = reply?.ok ? 'yes' : (reply?.error || 'no');
  render();
}

function done() {
  const state = snap?.state;
  const pro = !!state?.plan?.features?.blockInBrowser;
  const ok = (text, extra = null) => h('div', { class: 'item' }, h('span', { class: 'ok' }, icons.yes()), h('span', { class: 'grow' }, text), extra);
  const warn = (text, extra = null) => h('div', { class: 'item' }, h('span', { class: 'warn' }, icons.clock({ width: 14, height: 14 })), h('span', { class: 'grow' }, text), extra);
  const connected = snap?.conn === Conn.connected;
  return [
    stepper('done'),
    h('div', { class: 'done-mark' }, shieldIcon({ size: 64, solid: true, check: true, color: 'var(--indigo-fill)' })),
    h('h1', null, "You're set."),
    h('p', { class: 'lede' }, pro
      ? 'Start a session from the shield in the toolbar or from the menu bar. Distracting pages stay closed while you focus.'
      : 'Start a session from the shield in the toolbar or from the menu bar. Distracting tabs pause when you drift.'),
    h('section', { class: 'summary', 'aria-label': 'Setup summary' },
      connected
        ? ok(`Connected to FocusGuard ${state?.app?.version || ''}`.trim(), h('span', { class: 'faint' }, 'on this Mac'))
        : warn("FocusGuard isn't connected right now"),
      pinned ? ok('Pinned to the toolbar') : warn('Not pinned yet', h('span', { class: 'faint' }, 'puzzle piece › pin')),
      pro
        ? ok('Pro: pages that never load, parts of sites, YouTube video by video', h('span', { class: 'badge badge-pro' }, state.plan.tier === 'trial' ? 'TRIAL' : 'PRO'))
        : ok('Free plan: time per site, and tabs that pause when you drift', h('span', { class: 'badge badge-free' }, 'FREE')),
      pro && !siteAccess
        ? warn('Blocking needs site access', h('a', { href: '#', onclick: async (e) => {
          e.preventDefault();
          if (await chrome.permissions.request(SITE_ACCESS).catch(() => false)) await tell({ type: 'requestSiteAccess' });
          refresh();
        } }, 'Allow'))
        : null,
      incognito
        ? ok('Private windows are covered too')
        : warn("Private windows aren't covered yet", h('a', { href: '#', onclick: (e) => { e.preventDefault(); chrome.tabs.create({ url: `chrome://extensions/?id=${chrome.runtime.id}` }); } }, 'Allow'))),
    h('div', { class: 'row-actions' },
      started === 'yes'
        ? h('button', { class: 'btn btn-primary', disabled: true }, 'Session started')
        : h('button', { class: 'btn btn-primary', 'data-autofocus': true, disabled: !connected, onclick: startFifty }, 'Start a 50-minute session'),
      h('button', { class: 'btn btn-quiet', onclick: closeThisTab }, 'Close this tab')),
    started && started !== 'yes'
      ? h('p', { class: 'small-print', role: 'alert' }, started === 'alreadyRunning' ? 'A session is already running.' : "Couldn't start it. Is FocusGuard open?")
      : null,
    pro ? null : h('div', { class: 'pro-line' },
      h('span', null, "Want distracting pages to never load at all? That's FocusGuard Pro, 14 days free."),
      h('a', { href: '#', onclick: (e) => { e.preventDefault(); tell({ type: 'openApp', page: 'upgrade' }); } }, 'See Pro')),
  ];
}
