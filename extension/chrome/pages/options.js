// Options: connection and permissions, the blocked list as the app has it
// (read-only here), YouTube video by video, what the extension shares, and
// the toolbar badge.

import { Conn, GET_APP_URL } from '../src/lib/protocol.js';
import { appIcon, h, icons, reportAppearance, shieldIcon, subscribe, tell } from '../src/lib/dom.js';

const app = document.getElementById('app');
const SITE_ACCESS = { permissions: ['scripting'], origins: ['<all_urls>'] };

let snap = null;
let siteAccess = false;
let incognito = false;
let renderedKey = '';

reportAppearance();
subscribe('options', (next) => { snap = next; render(); });
refreshPermissions();
chrome.permissions.onAdded.addListener(refreshPermissions);
chrome.permissions.onRemoved.addListener(refreshPermissions);
// Private-window access changes on chrome://extensions; check when we're back.
document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshPermissions(); });

async function refreshPermissions() {
  siteAccess = await chrome.permissions.contains(SITE_ACCESS);
  incognito = await chrome.extension.isAllowedIncognitoAccess();
  render();
}

async function allowSiteAccess() {
  if (await chrome.permissions.request(SITE_ACCESS).catch(() => false)) {
    await tell({ type: 'requestSiteAccess' });
  }
  refreshPermissions();
}

async function removeSiteAccess() {
  await chrome.permissions.remove(SITE_ACCESS).catch(() => false);
  await tell({ type: 'requestSiteAccess' });
  refreshPermissions();
}

function openExtensionsPage() {
  chrome.tabs.create({ url: `chrome://extensions/?id=${chrome.runtime.id}` });
}

function openApp(page) {
  tell({ type: 'openApp', page: page || null });
}

function setSetting(key, value) {
  tell({ type: 'setSetting', key, value });
}

// ---------------------------------------------------------------------------

function render() {
  if (!snap) return;
  const key = JSON.stringify({ conn: snap.conn, plan: snap.state?.plan, app: snap.state?.app, blocking: snap.state?.blocking, settings: snap.settings, siteAccess, incognito });
  if (key === renderedKey) return;
  renderedKey = key;
  const state = snap.state;
  const pro = !!state?.plan?.features?.blockInBrowser;
  app.replaceChildren(
    h('header', { class: 'top' },
      appIcon(40),
      h('div', null,
        h('h1', null, 'FocusGuard extension'),
        h('div', { class: 'sub' }, `Version ${chrome.runtime.getManifest().version} · works in Chrome, Arc, Brave and Edge`))),
    h('div', { class: 'columns' },
      h('div', { class: 'column' }, connectionPanel(state, pro), listPanel(state, pro)),
      h('div', { class: 'column' }, state?.plan?.features?.youtubePerVideo ? youtubePanel() : proPanel(), sharesPanel(state), badgePanel())));
}

function switchButton(id, checked, onChange, disabled = false) {
  return h('button', {
    class: 'switch', role: 'switch', 'aria-checked': String(checked), 'aria-labelledby': id, disabled,
    onclick: () => onChange(!checked),
  }, h('span'));
}

function connectionPanel(state, pro) {
  const connected = snap.conn === Conn.connected && state;
  const head = connected
    ? h('div', { class: 'conn-head' },
      shieldIcon({ size: 28, solid: true, check: true, color: 'var(--indigo-fill)' }),
      h('div', { class: 'text' },
        h('div', { class: 'title' }, 'Connected to FocusGuard on this Mac',
          h('span', { class: `badge ${state.plan.pro ? 'badge-pro' : 'badge-free'}` }, state.plan.tier === 'trial' ? 'TRIAL' : state.plan.pro ? 'PRO' : 'FREE')),
        h('div', { class: 'detail' }, `FocusGuard ${state.app.version || ''} · talks to the app directly, never over the internet`)),
      h('button', { class: 'small-btn', onclick: () => openApp() }, 'Open FocusGuard'))
    : h('div', { class: 'conn-head' },
      shieldIcon({ size: 28, color: 'var(--grey)', slashed: true }),
      h('div', { class: 'text' },
        h('div', { class: 'title' }, snap.conn === Conn.notInstalled ? "FocusGuard isn't on this Mac" : "FocusGuard isn't running"),
        h('div', { class: 'detail' }, snap.conn === Conn.notInstalled
          ? 'The extension works with FocusGuard for Mac.'
          : 'Open it to count your time here and pause distracting tabs.')),
      snap.conn === Conn.notInstalled
        ? h('button', { class: 'small-btn', onclick: () => chrome.tabs.create({ url: GET_APP_URL }) }, 'Get FocusGuard')
        : h('button', { class: 'small-btn', onclick: () => openApp() }, 'Open FocusGuard'));

  const accessRow = pro
    ? h('div', { class: 'row' },
      h('div', { class: 'text' }, h('div', { class: 'label' }, 'Site access'), h('div', { class: 'hint' }, 'Needed to block pages before they load')),
      siteAccess ? h('span', { class: 'value' }, 'All sites') : h('a', { href: '#', onclick: (e) => { e.preventDefault(); allowSiteAccess(); } }, 'Allow'))
    : h('div', { class: 'row' },
      h('div', { class: 'text' }, h('div', { class: 'label' }, 'Site access'),
        h('div', { class: 'hint' }, 'Not needed on the free plan. Pro asks for it when you turn on browser blocking.')),
      siteAccess
        ? h('a', { href: '#', onclick: (e) => { e.preventDefault(); removeSiteAccess(); } }, 'Remove')
        : h('span', { class: 'value' }, 'None'));

  const privateRow = h('div', { class: 'row' },
    h('div', { class: 'text' }, h('div', { class: 'label' }, 'Private windows'),
      h('div', { class: 'hint' }, incognito
        ? `On: ${pro ? 'blocked' : 'paused'} and counted in private windows too`
        : `Off: nothing is ${pro ? 'blocked' : 'paused'} or counted in private windows`)),
    h('a', { href: '#', onclick: (e) => { e.preventDefault(); openExtensionsPage(); } }, incognito ? 'Change' : 'Allow in private windows'));

  return h('section', { class: 'panel', 'aria-label': 'Connection', style: { paddingBottom: '6px' } }, head, accessRow, privateRow);
}

function listPanel(state, pro) {
  const b = state?.blocking;
  const limits = new Map((b?.limits || []).map((l) => [l.site, l]));
  const freeLimit = state?.plan?.features?.unlimitedLimits ? '' : ' · your 1 free limit';
  const rows = [];
  for (const site of b?.sites || []) {
    const limit = limits.get(site);
    rows.push(h('div', { class: 'site-row' },
      h('span', { class: 'site' }, site),
      limit ? h('span', { class: 'limit' }, `${limit.minutes} min a day${freeLimit}`) : null,
      h('span', { class: 'kind' }, 'Whole site')));
    limits.delete(site);
  }
  for (const [site, limit] of limits) {
    rows.push(h('div', { class: 'site-row' },
      h('span', { class: 'site' }, site),
      h('span', { class: 'limit' }, `${limit.minutes} min a day${freeLimit}`),
      h('span', { class: 'kind' }, 'Daily limit')));
  }
  const parts = !!state?.plan?.features?.partsOfSites;
  for (const part of b?.parts || []) {
    rows.push(h('div', { class: 'site-row' },
      h('span', { class: 'site' }, part),
      h('span', { class: 'kind' }, parts ? null : icons.lock({ width: 12, height: 12 }), parts ? 'Part of a site' : 'Part of a site, needs Pro')));
  }
  return h('section', { class: 'panel', 'aria-label': pro ? 'Blocked during sessions' : 'Distracting sites', style: { paddingBottom: '12px' } },
    h('div', { class: 'list-head' },
      h('div', { class: 'text' },
        h('h2', null, pro ? 'Blocked during sessions' : 'Paused during sessions'),
        h('div', { class: 'hint' }, pro ? 'Synced from FocusGuard · edit the list there' : 'Synced from FocusGuard · tabs pause when the block screen shows')),
      h('button', { class: 'small-btn accent', onclick: () => openApp('blocking') }, 'Edit in FocusGuard')),
    rows.length ? rows : h('div', { class: 'empty' }, state
      ? 'Nothing yet. Sites you mark Distracting in FocusGuard show up here.'
      : 'Shows once FocusGuard is connected.'));
}

function youtubePanel() {
  const on = snap.settings?.youtubePerVideo !== false;
  return h('section', { class: 'panel', 'aria-label': 'YouTube', style: { gap: '6px' } },
    h('div', { class: 'switch-row' },
      h('span', { id: 'yt-label', class: 'label' }, 'Decide YouTube video by video'),
      switchButton('yt-label', on, (value) => setSetting('youtubePerVideo', value), !siteAccess)),
    h('div', { class: 'body' }, "FocusGuard reads each video's title and channel and sorts it on this Mac. A Swift talk counts as focus, a gaming stream doesn't."),
    h('div', { class: 'hint' }, siteAccess ? 'Off: all of youtube.com follows its own category.' : 'Needs site access, to read the channel.'));
}

function proPanel() {
  return h('section', { class: 'panel pro-panel', 'aria-label': 'Block before pages load' },
    h('div', { class: 'head' }, h('span', null, 'Block before pages load'), h('span', { class: 'badge badge-pro' }, 'PRO')),
    h('div', { class: 'list' },
      h('span', null, "Distracting pages never open, so there's nothing to peek at"),
      h('span', null, 'Parts of sites, like youtube.com/shorts and linkedin.com/feed'),
      h('span', null, 'YouTube sorted video by video'),
      h('span', null, 'Daily limits on as many sites as you like')),
    h('a', { href: '#', onclick: (e) => { e.preventDefault(); openApp('upgrade'); } }, 'See Pro, free for 14 days'));
}

function sharesPanel(state) {
  const line = (yes, text) => h('div', { class: `line ${yes ? 'yes' : 'no'}` }, yes ? icons.yes() : icons.no(), h('span', null, text));
  const video = !!state?.plan?.features?.youtubePerVideo && siteAccess && snap.settings?.youtubePerVideo !== false;
  return h('section', { class: 'panel shares', 'aria-label': 'What this extension shares' },
    h('h2', null, 'What this extension shares'),
    h('div', { class: 'group' },
      h('div', { class: 'group-title' }, 'Sends to FocusGuard on this Mac'),
      line(true, "The address and title of the tab you're looking at, each time it changes"),
      video ? line(true, "A YouTube video's title and channel, while video by video is on") : null),
    h('div', { class: 'group' },
      h('div', { class: 'group-title' }, 'Never'),
      line(false, "Talks to a server. There's no FocusGuard server for it to talk to."),
      line(false, video
        ? 'Reads anything else on a page, what you type, passwords or cookies'
        : "Reads what's on a page, what you type, passwords or cookies"),
      line(false, 'Looks at background tabs or your browsing history'),
      line(false, 'Runs in private windows, unless you allow it')));
}

function badgePanel() {
  const on = !!snap.settings?.badgeMinutes;
  return h('section', { class: 'panel', 'aria-label': 'Toolbar button' },
    h('div', { class: 'switch-row' },
      h('div', { class: 'stack' },
        h('span', { id: 'badge-label', style: { fontSize: '14px', fontWeight: 600 } }, 'Show minutes left on the toolbar button'),
        h('span', { class: 'hint' }, 'During a session, as a small badge')),
      switchButton('badge-label', on, (value) => setSetting('badgeMinutes', value))));
}
