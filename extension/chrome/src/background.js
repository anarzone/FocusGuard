// FocusGuard's background service worker.
//
// - Keeps a native-messaging port to FocusGuard's helper, which relays to
//   the app on this Mac. The open port also keeps this worker alive.
// - Reports the tab in front (address and title) each time it changes.
// - Free: pauses a distracting tab when the app's block screen comes up.
// - Pro (only when the app says so, and only with site access): blocks
//   sites and parts of sites before they load, and daily limits.
// - Draws the toolbar button.
//
// Nothing here talks to a server.

import {
  Conn, HOST_NAME, PROTOCOL_VERSION, PageMessage, REQUEST_TIMEOUT_MS,
  connFromDisconnect, requestId,
} from './lib/protocol.js';
import { displayHost, hostname, isWebURL, parseFragment, safeWebURL } from './lib/format.js';
import { blockReason, buildRules, hostMatches, rulesKey } from './lib/blocking.js';
import { passFor, toolbar } from './lib/view.js';
import { glyphImages } from './lib/icon.js';

const BLOCK_PAGE = chrome.runtime.getURL('pages/block.html');
const ALL_SITES = { origins: ['<all_urls>'] };
const SITE_ACCESS = { permissions: ['scripting'], origins: ['<all_urls>'] };

const DEFAULT_SETTINGS = {
  badgeMinutes: false,     // minutes left on the toolbar button
  youtubePerVideo: true,   // Pro: send each video's title and channel
  hideProCard: false,      // popup: the free plan's Pro card was hidden
  dark: false,             // last appearance a page reported, for the glyph
};

let port = null;
let conn = Conn.connecting;
let appPath = null;
let state = null;
let settings = { ...DEFAULT_SETTINGS };
let lastConnectedAt = null;
let retryDelay = 2000;
let retryTimer = null;
let lastRulesKey = null;
let lastTab = null;            // what we last reported: { tabId, url, title }
let activeHost = null;         // host of the tab in front, for the pass badge
const pending = new Map();     // request id → { resolve, timer }
const pagePorts = new Set();   // popup, options, block and welcome pages

// ---------------------------------------------------------------------------
// Startup

const ready = (async () => {
  const stored = await chrome.storage.local.get(['settings', 'lastConnectedAt']);
  settings = { ...DEFAULT_SETTINGS, ...(stored.settings || {}) };
  lastConnectedAt = stored.lastConnectedAt || null;
  // Pass expiry and the toolbar's countdowns.
  chrome.alarms.create('tick', { periodInMinutes: 0.5 });
  connect();
  updateToolbar();
})();

chrome.runtime.onInstalled.addListener(({ reason }) => {
  if (reason === chrome.runtime.OnInstalledReason.INSTALL) {
    chrome.tabs.create({ url: chrome.runtime.getURL('pages/welcome.html') });
  }
});

chrome.alarms.onAlarm.addListener(async () => {
  await ready;
  if (!port) connect();
  tick();
});

// ---------------------------------------------------------------------------
// Native connection

function connect() {
  if (port) return;
  clearTimeout(retryTimer);
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (error) {
    port = null;
    setConn(Conn.notInstalled);
    scheduleRetry();
    return;
  }
  port.onMessage.addListener(onNativeMessage);
  port.onDisconnect.addListener(() => {
    const message = chrome.runtime.lastError?.message;
    port = null;
    state = null;
    failPending('disconnected');
    setConn(connFromDisconnect(message));
    scheduleRetry();
  });
  // The helper answers with appStatus as soon as it knows whether the app
  // is running; until then, "connecting".
  if (conn !== Conn.connected) setConn(Conn.connecting);
}

function scheduleRetry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, retryDelay);
  retryDelay = Math.min(retryDelay * 2, 60000);
}

function reconnectNow() {
  retryDelay = 2000;
  if (port) {
    // Already talking to the helper: ask again rather than reconnecting.
    if (conn === Conn.notRunning) send({ type: 'hello', ...helloFields() });
    return;
  }
  connect();
}

function send(message) {
  if (!port) return false;
  try {
    port.postMessage(message);
    return true;
  } catch {
    return false;
  }
}

// Sends a request to the app and resolves with its reply.
function request(message) {
  return new Promise((resolve) => {
    const id = requestId();
    if (!send({ ...message, id })) {
      resolve({ ok: false, error: 'notConnected' });
      return;
    }
    const timer = setTimeout(() => {
      pending.delete(id);
      resolve({ ok: false, error: 'timeout' });
    }, REQUEST_TIMEOUT_MS);
    pending.set(id, { resolve, timer });
  });
}

function failPending(error) {
  for (const [id, entry] of pending) {
    clearTimeout(entry.timer);
    entry.resolve({ ok: false, error });
    pending.delete(id);
  }
}

function helloFields() {
  return {
    v: PROTOCOL_VERSION,
    extensionVersion: chrome.runtime.getManifest().version,
    siteAccess: siteAccessCache,
    incognito: incognitoCache,
  };
}

let siteAccessCache = false;
let incognitoCache = false;
async function refreshCapabilities() {
  siteAccessCache = await chrome.permissions.contains(ALL_SITES);
  incognitoCache = await chrome.extension.isAllowedIncognitoAccess();
}

async function onNativeMessage(message) {
  switch (message?.type) {
    case 'appStatus':
      appPath = message.appPath || appPath;
      if (message.running) {
        retryDelay = 2000;
        await refreshCapabilities();
        send({ type: 'hello', ...helloFields() });
        setConn(Conn.connected);
        reportActiveTab(true);
      } else {
        state = null;
        setConn(Conn.notRunning);
      }
      break;
    case 'state':
      onState(message);
      break;
    case 'reply': {
      const entry = pending.get(message.id);
      if (entry) {
        clearTimeout(entry.timer);
        pending.delete(message.id);
        entry.resolve(message);
      }
      break;
    }
    case 'pauseTab':
      send({ type: 'pauseResult', rid: message.rid, ok: await pauseTab(message) });
      break;
    case 'redirectTab':
      redirectTab(message);
      break;
    case 'refresh':
      reportActiveTab(true);
      break;
    default:
      break;
  }
}

function setConn(next) {
  if (next === Conn.connected) {
    lastConnectedAt = Date.now();
    chrome.storage.local.set({ lastConnectedAt });
  }
  if (conn === next && next !== Conn.connected) return;
  conn = next;
  if (conn !== Conn.connected) applyRules();
  updateToolbar();
  broadcast();
}

// ---------------------------------------------------------------------------
// App state

async function onState(next) {
  state = next;
  if (conn !== Conn.connected) setConn(Conn.connected);
  await applyRules();
  await enforceOnOpenTabs();
  updateToolbar();
  broadcast();
}

function tick() {
  updateToolbar();
  broadcast();
}

// ---------------------------------------------------------------------------
// Reporting the tab in front

let reportTimer = null;
function reportActiveTab(force = false) {
  clearTimeout(reportTimer);
  reportTimer = setTimeout(() => doReport(force), force ? 0 : 120);
}

async function doReport(force) {
  let tab = null;
  try {
    const win = await chrome.windows.getLastFocused();
    if (win?.focused) {
      [tab] = await chrome.tabs.query({ active: true, windowId: win.id });
    }
  } catch {
    tab = null;
  }
  activeHost = tab?.url ? hostname(tab.url) : null;
  const report = tab ? await describeTab(tab) : null;
  const key = JSON.stringify(report);
  if (!force && key === JSON.stringify(lastTab)) return;
  lastTab = report;
  if (conn === Conn.connected) send({ type: 'tab', tab: report });
  updateToolbar();
}

// What the app hears about a tab: its address (web pages only) and title.
// FocusGuard's own pages are reported without an address.
async function describeTab(tab) {
  const own = tab.url?.startsWith(chrome.runtime.getURL(''));
  const web = !own && isWebURL(tab.url || '');
  const report = { url: web ? tab.url : null, title: tab.title || null, tabId: tab.id, windowId: tab.windowId };
  if (web && state?.plan?.features?.youtubePerVideo && settings.youtubePerVideo && isYouTubeVideo(tab.url)) {
    const video = await readYouTubeVideo(tab);
    if (video) report.video = video;
  }
  return report;
}

function isYouTubeVideo(url) {
  try {
    const u = new URL(url);
    return /(^|\.)youtube\.com$/.test(u.hostname) && (u.pathname === '/watch' || u.pathname.startsWith('/live/'));
  } catch {
    return false;
  }
}

// Pro, video by video: the video's title and channel, read from the page.
// Needs site access; without it, only the tab title goes.
async function readYouTubeVideo(tab) {
  if (!(await chrome.permissions.contains(SITE_ACCESS))) return null;
  try {
    const [result] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => {
        const text = (el) => el?.textContent?.trim() || null;
        const channel = text(document.querySelector('ytd-video-owner-renderer #channel-name a'))
          || document.querySelector('span[itemprop="author"] link[itemprop="name"]')?.getAttribute('content')
          || null;
        const title = text(document.querySelector('h1.ytd-watch-metadata yt-formatted-string'))
          || document.title.replace(/ - YouTube$/, '');
        return { title, channel };
      },
    });
    return result?.result || null;
  } catch {
    return null;
  }
}

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  reportActiveTab();
  enforceOnTab(await chrome.tabs.get(tabId).catch(() => null));
});
chrome.windows.onFocusChanged.addListener(() => reportActiveTab());
chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (change.url) {
    // Left the calm page some other way: it's no longer paused.
    if (!change.url.startsWith(BLOCK_PAGE)) forgetPausedTab(tabId);
    enforceOnTab(tab);
  }
  if (tab.active && (change.url || change.title || change.status === 'complete')) reportActiveTab();
});
chrome.tabs.onRemoved.addListener((tabId) => forgetPausedTab(tabId));

// ---------------------------------------------------------------------------
// Free: pause the tab

async function pausedTabs() {
  return (await chrome.storage.session.get('pausedTabs')).pausedTabs || {};
}

async function savePausedTabs(tabs) {
  await chrome.storage.session.set({ pausedTabs: tabs });
}

async function forgetPausedTab(tabId) {
  const tabs = await pausedTabs();
  if (tabs[tabId]) {
    delete tabs[tabId];
    await savePausedTabs(tabs);
  }
}

// The tab showing `host` (or a subdomain): the one the app named, else the
// tab in front. Background tabs are never looked through.
async function findTab(host, tabId) {
  const matches = (t) => t?.url && hostMatches(hostname(t.url), host);
  if (tabId != null) {
    const tab = await chrome.tabs.get(tabId).catch(() => null);
    if (matches(tab)) return tab;
  }
  const [front] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return matches(front) ? front : null;
}

// The paused page with the app's fields, the same ones paused.html takes.
function pausePageURL(fragment) {
  return `${BLOCK_PAGE}?kind=paused#${fragment}`;
}

// The app's TabPauser: point the front tab at the paused page if it still
// shows `host`, and say whether it did.
async function pauseTab({ host, tabId, fragment }) {
  const fields = parseFragment(fragment);
  if (!fields.id || !host) return false;
  const tab = await findTab(host, tabId);
  if (!tab) return false;
  const tabs = await pausedTabs();
  tabs[tab.id] = { pauseId: fields.id, url: safeWebURL(fields.url) || tab.url, host };
  await savePausedTabs(tabs);
  try {
    await chrome.tabs.update(tab.id, { url: pausePageURL(fragment) });
    return true;
  } catch {
    delete tabs[tab.id];
    await savePausedTabs(tabs);
    return false;
  }
}

// The app moved a paused tab on: the page in another state, or the site.
// Only tabs this extension paused are looked at.
async function redirectTab({ pauseId, fragment, url }) {
  const tabs = await pausedTabs();
  const entry = Object.entries(tabs).find(([, e]) => e.pauseId === pauseId);
  if (!entry) return;
  const tabId = Number(entry[0]);
  const tab = await chrome.tabs.get(tabId).catch(() => null);
  if (!tab?.url?.includes(`id=${pauseId}&`) && !tab?.url?.endsWith(`id=${pauseId}`)) {
    delete tabs[tabId];
    await savePausedTabs(tabs);
    return;
  }
  const site = safeWebURL(url);
  if (site) {
    delete tabs[tabId];
    await savePausedTabs(tabs);
    await chrome.tabs.update(tabId, { url: site }).catch(() => {});
  } else if (fragment) {
    await chrome.tabs.update(tabId, { url: pausePageURL(fragment) }).catch(() => {});
  }
}

// "Reopen x.com" on the page once the session is over.
async function reopenTab(tabId, fallbackURL) {
  const tabs = await pausedTabs();
  const entry = tabs[tabId];
  const url = entry?.url || safeWebURL(fallbackURL);
  if (entry) {
    delete tabs[tabId];
    await savePausedTabs(tabs);
  }
  if (!url) return false;
  await chrome.tabs.update(tabId, { url }).catch(() => {});
  return true;
}

// ---------------------------------------------------------------------------
// Pro: blocking before pages load

async function blockingAllowed() {
  return !!state?.plan?.features?.blockInBrowser && conn === Conn.connected && (await chrome.permissions.contains(ALL_SITES));
}

async function applyRules() {
  const rules = (await blockingAllowed()) ? buildRules(state, BLOCK_PAGE) : [];
  const key = rulesKey(rules);
  if (key === lastRulesKey) return;
  try {
    const existing = await chrome.declarativeNetRequest.getSessionRules();
    await chrome.declarativeNetRequest.updateSessionRules({
      removeRuleIds: existing.map((r) => r.id),
      addRules: rules,
    });
    lastRulesKey = key;
  } catch (error) {
    console.warn('FocusGuard: could not update blocking rules', error);
  }
}

function blockPageURL(url, reason) {
  const params = new URLSearchParams({ kind: reason.kind, target: reason.target });
  return `${BLOCK_PAGE}?${params}#${url}`;
}

// Rules only stop new loads. Pages already open, or changed inside the page
// (YouTube Shorts), are sent to the block page here.
async function enforceOnTab(tab) {
  if (!tab?.url || !isWebURL(tab.url) || !(await blockingAllowed())) return;
  const reason = blockReason(tab.url, state);
  if (!reason) return;
  await chrome.tabs.update(tab.id, { url: blockPageURL(tab.url, reason) }).catch(() => {});
}

// After a state change (a session started, a pass ran out, a limit was
// reached): the tabs in front go to the block page now; tabs behind them
// when they're next opened.
async function enforceOnOpenTabs() {
  if (!(await blockingAllowed())) return;
  const tabs = await chrome.tabs.query({ active: true, url: ['http://*/*', 'https://*/*'] });
  for (const tab of tabs) await enforceOnTab(tab);
}

// The in-page countdown while a pass runs (needs site access).
async function showPassPill(tabId, until) {
  if (!(await chrome.permissions.contains(SITE_ACCESS))) return;
  const backTo = state?.session?.backTo || null;
  chrome.scripting.executeScript({
    target: { tabId },
    args: [until, backTo],
    func: (untilMs, backToName) => {
      document.getElementById('focusguard-pass')?.remove();
      const pill = document.createElement('div');
      pill.id = 'focusguard-pass';
      pill.setAttribute('role', 'status');
      const shadow = pill.attachShadow({ mode: 'closed' });
      shadow.innerHTML = `
        <style>
          :host { all: initial; position: fixed; z-index: 2147483647; left: 50%; bottom: 24px; transform: translateX(-50%); }
          .pill { display: flex; align-items: center; gap: 12px; padding: 8px 8px 8px 14px; border-radius: 22px;
            background: #1D1D1F; color: #F5F5F7; font: 13px -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            box-shadow: 0 10px 30px rgba(0,0,0,0.28); }
          .dot { width: 10px; height: 10px; border-radius: 5px; background: #FF8D28; flex: none; }
          .text { display: flex; flex-direction: column; gap: 1px; }
          .main { font-weight: 600; font-variant-numeric: tabular-nums; }
          .sub { font-size: 11px; color: #C7C7CF; }
          button { all: unset; cursor: pointer; height: 30px; padding: 0 14px; border-radius: 15px; background: #6155F5;
            color: #fff; font-weight: 600; font-size: 12px; }
          button:focus-visible { outline: 2px solid #9AA3FF; outline-offset: 2px; }
        </style>
        <div class="pill"><span class="dot"></span><span class="text"><span class="main"></span>
        <span class="sub">You let yourself through · this counts as drift</span></span><button type="button"></button></div>`;
      const main = shadow.querySelector('.main');
      const button = shadow.querySelector('button');
      button.textContent = backToName ? `Back to ${backToName}` : 'Close tab';
      button.addEventListener('click', () => chrome.runtime.sendMessage({ type: 'backToWork' }));
      const host = location.hostname.replace(/^www\./, '');
      const tickPill = () => {
        const left = Math.max(0, Math.ceil((untilMs - Date.now()) / 1000));
        main.textContent = `${host} closes in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
        if (left <= 0) { clearInterval(timer); pill.remove(); }
      };
      const timer = setInterval(tickPill, 1000);
      tickPill();
      document.documentElement.appendChild(pill);
    },
  }).catch(() => {});
}

// ---------------------------------------------------------------------------
// Block page actions

async function passThrough(tabId, url) {
  const reply = await request({ type: 'requestPass', host: hostname(url) });
  if (!reply.ok) return reply;
  // Wait for the state with the pass, so the rules let the page through.
  const until = reply.result?.until;
  if (until && state) {
    const host = hostname(url);
    if (!passFor(state, host)) {
      state = { ...state, blocking: { ...state.blocking, passes: [...(state.blocking.passes || []), { host, until }] } };
    }
    await applyRules();
  }
  await chrome.tabs.update(tabId, { url });
  if (until) {
    const onLoad = (id, change) => {
      if (id === tabId && change.status === 'complete') {
        chrome.tabs.onUpdated.removeListener(onLoad);
        showPassPill(tabId, until);
      }
    };
    chrome.tabs.onUpdated.addListener(onLoad);
  }
  return reply;
}

async function forWork(tabId, url) {
  const reply = await request({ type: 'allowForWork', host: hostname(url) });
  if (!reply.ok) return reply;
  const host = hostname(url);
  if (state && !(state.blocking.allowed || []).includes(host)) {
    state = { ...state, blocking: { ...state.blocking, allowed: [...(state.blocking.allowed || []), host] } };
  }
  await applyRules();
  await chrome.tabs.update(tabId, { url });
  return reply;
}

async function backToWork(tabId) {
  const reply = await request({ type: 'backToWork' });
  // No focus app to go back to: close the tab instead.
  if (!reply.ok || !reply.result?.app) {
    if (tabId != null) await chrome.tabs.remove(tabId).catch(() => {});
  }
  return reply;
}

// ---------------------------------------------------------------------------
// Toolbar

function updateToolbar() {
  const view = toolbar({ conn, state, activeHost, badgeMinutes: settings.badgeMinutes });
  chrome.action.setIcon({ imageData: glyphImages(view.kind, view.fill, settings.dark) }).catch(() => {});
  chrome.action.setTitle({ title: view.title });
  chrome.action.setBadgeText({ text: view.badge?.text || '' });
  if (view.badge) {
    chrome.action.setBadgeBackgroundColor({ color: view.badge.color });
    chrome.action.setBadgeTextColor?.({ color: view.badge.textColor });
  }
  // A running pass counts down by the second.
  const passRunning = view.badge && view.badge.color === '#FF8D28';
  if (passRunning && !passTicker) passTicker = setInterval(updateToolbar, 1000);
  if (!passRunning && passTicker) { clearInterval(passTicker); passTicker = null; }
}
let passTicker = null;

// ---------------------------------------------------------------------------
// Pages (popup, options, block, welcome)

function snapshot() {
  return {
    type: PageMessage.snapshot,
    conn, state, settings, appPath, lastConnectedAt,
    now: Date.now(),
  };
}

function broadcast() {
  const message = snapshot();
  for (const p of pagePorts) {
    try { p.postMessage(message); } catch { pagePorts.delete(p); }
  }
}

chrome.runtime.onConnect.addListener(async (p) => {
  await ready;
  pagePorts.add(p);
  p.onDisconnect.addListener(() => pagePorts.delete(p));
  p.postMessage(snapshot());
  // Opening the popup is a good moment to retry a missing app.
  if (conn !== Conn.connected) reconnectNow();
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handlePageMessage(message, sender).then(sendResponse, (error) => sendResponse({ ok: false, error: String(error) }));
  return true;
});

async function handlePageMessage(message, sender) {
  await ready;
  const tabId = sender.tab?.id;
  switch (message?.type) {
    case PageMessage.request:
      return request(message.payload);
    case PageMessage.reconnect:
      reconnectNow();
      return { ok: true };
    case PageMessage.setSetting: {
      settings = { ...settings, [message.key]: message.value };
      await chrome.storage.local.set({ settings });
      updateToolbar();
      broadcast();
      if (message.key === 'youtubePerVideo') reportActiveTab(true);
      return { ok: true };
    }
    case PageMessage.appearance:
      if (settings.dark !== !!message.dark) {
        settings = { ...settings, dark: !!message.dark };
        await chrome.storage.local.set({ settings });
        updateToolbar();
      }
      return { ok: true };
    case 'openApp':
      // Works whether or not the app is running: the helper opens it.
      if (!send({ type: 'openApp', page: message.page || null })) {
        reconnectNow();
        return { ok: false, error: 'notConnected' };
      }
      return { ok: true };
    case 'backToWork':
      return backToWork(tabId);
    case PageMessage.reopenTab:
      return { ok: await reopenTab(tabId, message.url) };
    case 'tabAction':
      // The paused page's buttons, answered by the app's own routes.
      return request({ type: 'tabAction', action: message.action, pauseId: message.pauseId || null, minutes: message.minutes || null });
    case PageMessage.closeTab:
      if (tabId != null) await chrome.tabs.remove(tabId).catch(() => {});
      return { ok: true };
    case PageMessage.passThrough:
      return passThrough(tabId, message.url);
    case PageMessage.forWork:
      return forWork(tabId, message.url);
    case PageMessage.extraTime: {
      const reply = await request({ type: 'requestExtraTime', site: message.site });
      if (!reply.ok) return reply;
      // Lift the limit's rule before going back, rather than wait for the state.
      if (state) {
        const limits = (state.blocking.limits || []).map((l) => (l.site === message.site ? { ...l, reached: false } : l));
        state = { ...state, blocking: { ...state.blocking, limits } };
        await applyRules();
      }
      if (message.url) await chrome.tabs.update(tabId, { url: message.url });
      return reply;
    }
    case PageMessage.blockedVisit:
      send({ type: 'blockedVisit', host: message.host });
      return { ok: true };
    case PageMessage.goTo:
      if (tabId != null && isWebURL(message.url)) await chrome.tabs.update(tabId, { url: message.url });
      return { ok: true };
    case 'requestSiteAccess':
      // Pages ask for it from a click; the result lands here.
      await refreshCapabilities();
      send({ type: 'hello', ...helloFields() });
      lastRulesKey = null;
      await applyRules();
      broadcast();
      return { ok: siteAccessCache };
    default:
      return { ok: false, error: 'unknown' };
  }
}

chrome.permissions.onAdded.addListener(async () => {
  await refreshCapabilities();
  lastRulesKey = null;
  await applyRules();
  broadcast();
});
chrome.permissions.onRemoved.addListener(async () => {
  await refreshCapabilities();
  lastRulesKey = null;
  await applyRules();
  broadcast();
});
