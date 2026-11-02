// Options: connection and permissions, the blocked list as the app has it
// (read-only here), YouTube video by video, what the extension shares, and
// the toolbar badge.

import { Conn, GET_APP_URL } from '../src/lib/protocol.js';
import { t } from '../src/lib/i18n.js';
import { appIcon, h, icons, localizePage, reportAppearance, shieldIcon, subscribe, tell } from '../src/lib/dom.js';

await localizePage();

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
        h('h1', null, t('optionsHeading')),
        h('div', { class: 'sub' }, t('optionsVersion', chrome.runtime.getManifest().version)))),
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
        h('div', { class: 'title' }, t('optionsConnected'),
          h('span', { class: `badge ${state.plan.pro ? 'badge-pro' : 'badge-free'}` }, state.plan.tier === 'trial' ? t('badgeTrial') : state.plan.pro ? t('badgePro') : t('badgeFree'))),
        h('div', { class: 'detail' }, t('optionsConnectedDetail', state.app.version || ''))),
      h('button', { class: 'small-btn', onclick: () => openApp() }, t('openApp')))
    : h('div', { class: 'conn-head' },
      shieldIcon({ size: 28, color: 'var(--grey)', slashed: true }),
      h('div', { class: 'text' },
        h('div', { class: 'title' }, snap.conn === Conn.notInstalled ? t('optionsNotOnMac') : t('appNotRunning')),
        h('div', { class: 'detail' }, snap.conn === Conn.notInstalled
          ? t('optionsWorksWithMac')
          : t('optionsOpenToCount'))),
      snap.conn === Conn.notInstalled
        ? h('button', { class: 'small-btn', onclick: () => chrome.tabs.create({ url: GET_APP_URL }) }, t('getApp'))
        : h('button', { class: 'small-btn', onclick: () => openApp() }, t('openApp')));

  const accessRow = pro
    ? h('div', { class: 'row' },
      h('div', { class: 'text' }, h('div', { class: 'label' }, t('optionsSiteAccess')), h('div', { class: 'hint' }, t('optionsSiteAccessProHint'))),
      siteAccess ? h('span', { class: 'value' }, t('optionsAllSites')) : h('a', { href: '#', onclick: (e) => { e.preventDefault(); allowSiteAccess(); } }, t('allow')))
    : h('div', { class: 'row' },
      h('div', { class: 'text' }, h('div', { class: 'label' }, t('optionsSiteAccess')),
        h('div', { class: 'hint' }, t('optionsSiteAccessFreeHint'))),
      siteAccess
        ? h('a', { href: '#', onclick: (e) => { e.preventDefault(); removeSiteAccess(); } }, t('optionsRemove'))
        : h('span', { class: 'value' }, t('optionsNone')));

  const privateRow = h('div', { class: 'row' },
    h('div', { class: 'text' }, h('div', { class: 'label' }, t('optionsPrivateWindows')),
      h('div', { class: 'hint' }, incognito
        ? (pro ? t('optionsPrivateOnBlocked') : t('optionsPrivateOnPaused'))
        : (pro ? t('optionsPrivateOffBlocked') : t('optionsPrivateOffPaused')))),
    h('a', { href: '#', onclick: (e) => { e.preventDefault(); openExtensionsPage(); } }, incognito ? t('optionsChange') : t('optionsAllowPrivate')));

  return h('section', { class: 'panel', 'aria-label': t('optionsConnectionLabel'), style: { paddingBottom: '6px' } }, head, accessRow, privateRow);
}

function listPanel(state, pro) {
  const b = state?.blocking;
  const limits = new Map((b?.limits || []).map((l) => [l.site, l]));
  const limitText = (minutes) => (state?.plan?.features?.unlimitedLimits ? t('optionsLimitPerDay', minutes) : t('optionsLimitPerDayFree', minutes));
  const rows = [];
  for (const site of b?.sites || []) {
    const limit = limits.get(site);
    rows.push(h('div', { class: 'site-row' },
      h('span', { class: 'site' }, site),
      limit ? h('span', { class: 'limit' }, limitText(limit.minutes)) : null,
      h('span', { class: 'kind' }, t('optionsWholeSite'))));
    limits.delete(site);
  }
  for (const [site, limit] of limits) {
    rows.push(h('div', { class: 'site-row' },
      h('span', { class: 'site' }, site),
      h('span', { class: 'limit' }, limitText(limit.minutes)),
      h('span', { class: 'kind' }, t('limitTag'))));
  }
  const parts = !!state?.plan?.features?.partsOfSites;
  for (const part of b?.parts || []) {
    rows.push(h('div', { class: 'site-row' },
      h('span', { class: 'site' }, part),
      h('span', { class: 'kind' }, parts ? null : icons.lock({ width: 12, height: 12 }), parts ? t('optionsPartOfSite') : t('optionsPartNeedsPro'))));
  }
  return h('section', { class: 'panel', 'aria-label': pro ? t('optionsBlockedHeading') : t('optionsDistractingLabel'), style: { paddingBottom: '12px' } },
    h('div', { class: 'list-head' },
      h('div', { class: 'text' },
        h('h2', null, pro ? t('optionsBlockedHeading') : t('optionsPausedHeading')),
        h('div', { class: 'hint' }, pro ? t('optionsSyncedPro') : t('optionsSyncedFree'))),
      h('button', { class: 'small-btn accent', onclick: () => openApp('blocking') }, t('optionsEditInApp'))),
    rows.length ? rows : h('div', { class: 'empty' }, state
      ? t('optionsNothingYet')
      : t('optionsShowsOnceConnected')));
}

function youtubePanel() {
  const on = snap.settings?.youtubePerVideo !== false;
  return h('section', { class: 'panel', 'aria-label': 'YouTube', style: { gap: '6px' } },
    h('div', { class: 'switch-row' },
      h('span', { id: 'yt-label', class: 'label' }, t('optionsYoutubeTitle')),
      switchButton('yt-label', on, (value) => setSetting('youtubePerVideo', value), !siteAccess)),
    h('div', { class: 'body' }, t('optionsYoutubeBody')),
    h('div', { class: 'hint' }, siteAccess ? t('optionsYoutubeOffHint') : t('optionsYoutubeNeedsAccess')));
}

function proPanel() {
  return h('section', { class: 'panel pro-panel', 'aria-label': t('blockBeforeLoad') },
    h('div', { class: 'head' }, h('span', null, t('blockBeforeLoad')), h('span', { class: 'badge badge-pro' }, t('badgePro'))),
    h('div', { class: 'list' },
      h('span', null, t('optionsProNeverOpen')),
      h('span', null, t('optionsProParts')),
      h('span', null, t('proYoutube')),
      h('span', null, t('proLimits'))),
    h('a', { href: '#', onclick: (e) => { e.preventDefault(); openApp('upgrade'); } }, t('proTrial')));
}

function sharesPanel(state) {
  const line = (yes, text) => h('div', { class: `line ${yes ? 'yes' : 'no'}` }, yes ? icons.yes() : icons.no(), h('span', null, text));
  const video = !!state?.plan?.features?.youtubePerVideo && siteAccess && snap.settings?.youtubePerVideo !== false;
  return h('section', { class: 'panel shares', 'aria-label': t('optionsSharesHeading') },
    h('h2', null, t('optionsSharesHeading')),
    h('div', { class: 'group' },
      h('div', { class: 'group-title' }, t('optionsSendsToApp')),
      line(true, t('optionsShareAddress')),
      video ? line(true, t('optionsShareVideo')) : null),
    h('div', { class: 'group' },
      h('div', { class: 'group-title' }, t('optionsNever')),
      line(false, t('optionsNeverServer')),
      line(false, video
        ? t('optionsNeverReadsOther')
        : t('optionsNeverReads')),
      line(false, t('optionsNeverBackground')),
      line(false, t('optionsNeverPrivate'))));
}

function badgePanel() {
  const on = !!snap.settings?.badgeMinutes;
  return h('section', { class: 'panel', 'aria-label': t('optionsToolbarLabel') },
    h('div', { class: 'switch-row' },
      h('div', { class: 'stack' },
        h('span', { id: 'badge-label', style: { fontSize: '14px', fontWeight: 600 } }, t('optionsBadgeTitle')),
        h('span', { class: 'hint' }, t('optionsBadgeHint'))),
      switchButton('badge-label', on, (value) => setSetting('badgeMinutes', value))));
}
