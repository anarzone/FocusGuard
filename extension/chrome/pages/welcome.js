// First run: welcome, connect to the app, pin the button, done. Opens once,
// right after the extension is added.

import { Conn, GET_APP_URL } from '../src/lib/protocol.js';
import { t } from '../src/lib/i18n.js';
import { appIcon, ask, h, icons, localizePage, mount, reportAppearance, shieldIcon, subscribe, tell } from '../src/lib/dom.js';

await localizePage();

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
  const names = { connect: t('welcomeStepConnect'), pin: t('welcomeStepPin'), done: t('welcomeStepDone') };
  const at = order.indexOf(current);
  const items = [];
  order.forEach((id, i) => {
    if (i > 0) items.push(h('li', { class: 'rule', 'aria-hidden': 'true' }));
    const isDone = i < at || (id === 'done' && current === 'done');
    items.push(h('li', { 'aria-current': id === current ? 'step' : null },
      h('span', { class: `n${isDone && id !== current ? ' done' : ''}` }, isDone && id !== current ? icons.check({ size: 12 }) : String(i + 1)),
      h('span', null, names[id])));
  });
  return h('ol', { class: 'steps', 'aria-label': t('welcomeStepsLabel') }, items);
}

// --- 1. Welcome -------------------------------------------------------------

function welcome() {
  const feature = (glyph, badge, name, text) => h('div', { class: 'feature' },
    h('div', { class: 'top' }, h('div', { class: 'glyph', 'aria-hidden': 'true' }, glyph), h('span', { class: 'grow' }), badge),
    h('div', { class: 'name' }, name),
    h('div', { class: 'text' }, text));
  return [
    h('div', { class: 'hero-icon', 'aria-hidden': 'true' }, appIcon(88).firstChild),
    h('h1', null, t('welcomeTitle')),
    h('p', { class: 'lede' }, t('welcomeLede')),
    h('div', { class: 'features' },
      feature(icons.clock(), h('span', { class: 'badge badge-free' }, t('badgeFree')), t('welcomeTimeName'),
        t('welcomeTimeText')),
      feature(icons.lock(), h('span', { class: 'badge badge-pro' }, t('badgePro')), t('welcomeBlockName'),
        t('welcomeBlockText')),
      feature(shieldIcon({ size: 16, color: 'currentColor' }), null, t('welcomeMacName'),
        t('welcomeMacText'))),
    h('button', { class: 'btn btn-primary big-btn', 'data-autofocus': true, onclick: () => go('connect') }, t('welcomeSetUp')),
    h('div', { class: 'next' }, t('welcomeNext')),
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
        h('div', { class: 'title' }, t('welcomeNotOnMacTitle')),
        h('div', { class: 'detail' }, t('welcomeInstallOpen'))),
      h('button', { class: 'btn btn-primary', 'data-autofocus': true, onclick: () => chrome.tabs.create({ url: GET_APP_URL }) }, t('getForMac')))
    : h('div', { class: 'head' },
      appIcon(52),
      h('div', { class: 'text' },
        h('div', { class: 'title' }, conn === Conn.notRunning ? t('welcomeNotOpenTitle') : t('welcomeLookingTitle')),
        h('div', { class: 'detail' }, t('welcomeOpenMovesOn'))),
      h('button', { class: 'btn btn-primary', 'data-autofocus': true, onclick: () => tell({ type: 'openApp' }) }, t('openApp')));
  return [
    stepper('connect'),
    h('h1', null, t('welcomeConnectTitle')),
    h('p', { class: 'lede' }, t('welcomeConnectLede')),
    h('section', { class: 'panel', 'aria-label': t('welcomeAppLabel') },
      head,
      h('div', { class: 'status', role: 'status' },
        h('span', { class: 'spinner', 'aria-hidden': 'true' }),
        h('span', null, t('welcomeLookingStatus')),
        h('a', { href: '#', onclick: (e) => { e.preventDefault(); tell({ type: 'reconnect' }); } }, t('tryAgain')))),
    missing ? null : h('section', { class: 'quiet-panel', 'aria-label': t('getApp') },
      h('div', { class: 'text' },
        h('div', { class: 'title' }, t('welcomeNoAppTitle')),
        h('div', { class: 'detail' }, t('welcomeFreeNeeds'))),
      h('button', { class: 'btn btn-quiet', onclick: () => chrome.tabs.create({ url: GET_APP_URL }) }, t('getForMac'))),
    h('div', { class: 'small-print' }, t('welcomeNativeNote')),
  ];
}

// --- 3. Pin -----------------------------------------------------------------

function pin() {
  return [
    stepper('pin'),
    h('h1', null, t('welcomePinTitle')),
    h('p', { class: 'lede' }, t('welcomePinLede')),
    h('section', { class: 'panel how', 'aria-label': t('welcomeHowToPinLabel') },
      h('div', { class: 'step' },
        h('span', { class: 'num', 'aria-hidden': 'true' }, '1'),
        h('div', null,
          h('div', { class: 'title' }, t('welcomePinStep1')),
          h('div', { class: 'detail' }, t('welcomePinStep1Detail')))),
      h('div', { class: 'step' },
        h('span', { class: 'num', 'aria-hidden': 'true' }, '2'),
        h('div', null,
          h('div', { class: 'title' }, t('welcomePinStep2')),
          h('div', { class: 'detail' }, t('welcomePinStep2Detail')))),
      h('div', { class: 'status', role: 'status' },
        h('span', { class: 'spinner', 'aria-hidden': 'true' }),
        h('span', null, t('welcomeWaitingPin')),
        h('a', { href: '#', 'data-autofocus': true, onclick: (e) => { e.preventDefault(); skippedPin = true; go('done'); } }, t('welcomeSkip')))),
    h('div', { class: 'small-print' }, t('welcomeNoPuzzle')),
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
    h('h1', null, t('welcomeDoneTitle')),
    h('p', { class: 'lede' }, pro
      ? t('welcomeDoneLedePro')
      : t('welcomeDoneLedeFree')),
    h('section', { class: 'summary', 'aria-label': t('welcomeSummaryLabel') },
      connected
        ? ok(t('welcomeConnectedVersion', state?.app?.version || '').trim(), h('span', { class: 'faint' }, t('welcomeOnThisMac')))
        : warn(t('welcomeNotConnected')),
      pinned ? ok(t('welcomePinned')) : warn(t('welcomeNotPinned'), h('span', { class: 'faint' }, t('welcomePinPath'))),
      pro
        ? ok(t('welcomeSummaryPro'), h('span', { class: 'badge badge-pro' }, state.plan.tier === 'trial' ? t('badgeTrial') : t('badgePro')))
        : ok(t('welcomeSummaryFree'), h('span', { class: 'badge badge-free' }, t('badgeFree'))),
      pro && !siteAccess
        ? warn(t('welcomeNeedsAccess'), h('a', { href: '#', onclick: async (e) => {
          e.preventDefault();
          if (await chrome.permissions.request(SITE_ACCESS).catch(() => false)) await tell({ type: 'requestSiteAccess' });
          refresh();
        } }, t('allow')))
        : null,
      incognito
        ? ok(t('welcomePrivateCovered'))
        : warn(t('welcomePrivateNotCovered'), h('a', { href: '#', onclick: (e) => { e.preventDefault(); chrome.tabs.create({ url: `chrome://extensions/?id=${chrome.runtime.id}` }); } }, t('allow')))),
    h('div', { class: 'row-actions' },
      started === 'yes'
        ? h('button', { class: 'btn btn-primary', disabled: true }, t('welcomeSessionStarted'))
        : h('button', { class: 'btn btn-primary', 'data-autofocus': true, disabled: !connected, onclick: startFifty }, t('welcomeStartMinutes', 50)),
      h('button', { class: 'btn btn-quiet', onclick: closeThisTab }, t('welcomeCloseThisTab'))),
    started && started !== 'yes'
      ? h('p', { class: 'small-print', role: 'alert' }, started === 'alreadyRunning' ? t('sessionAlreadyRunning') : t('welcomeStartFailed'))
      : null,
    pro ? null : h('div', { class: 'pro-line' },
      h('span', null, t('welcomeProLine')),
      h('a', { href: '#', onclick: (e) => { e.preventDefault(); tell({ type: 'openApp', page: 'upgrade' }); } }, t('welcomeSeePro'))),
  ];
}
