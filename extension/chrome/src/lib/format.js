// Small helpers for addresses and times. The only chrome.* they touch is
// chrome.i18n, through i18n.js, which the tests stub.

import { plural, t, uiLanguage } from './i18n.js';

// "https://www.x.com/home" → "x.com"; null for anything but http(s).
export function displayHost(url) {
  try {
    const u = new URL(url);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    let host = u.hostname.toLowerCase();
    if (!host) return null;
    if (host.startsWith('www.')) host = host.slice(4);
    return host;
  } catch {
    return null;
  }
}

// The address's own hostname, lowercased (keeps "www.").
export function hostname(url) {
  try {
    return new URL(url).hostname.toLowerCase() || null;
  } catch {
    return null;
  }
}

// The paused page's fields ("id=…&host=…&state=…"), decoded, the same way
// the app's paused.html reads them.
export function parseFragment(text) {
  const out = {};
  for (const pair of String(text || '').replace(/^#/, '').split('&')) {
    if (!pair) continue;
    const i = pair.indexOf('=');
    const key = i < 0 ? pair : pair.slice(0, i);
    const value = i < 0 ? '' : pair.slice(i + 1);
    try { out[decodeURIComponent(key)] = decodeURIComponent(value.replace(/\+/g, ' ')); } catch { /* skip a bad pair */ }
  }
  return out;
}

// Only web pages can be reopened, never a script or file link.
export function safeWebURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null;
  } catch {
    return null;
  }
}

export function isWebURL(url) {
  return displayHost(url) !== null;
}

// "Only this article": host and path, no query or fragment.
export function pagePattern(url) {
  const host = displayHost(url);
  if (!host) return null;
  let path = new URL(url).pathname;
  while (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
  if (path.length <= 1) return null;
  return host + path;
}

// "youtube.com/shorts" → { host: "youtube.com", path: "/shorts" }
export function splitPart(pattern) {
  const p = String(pattern).toLowerCase().replace(/^[a-z]+:\/\//, '');
  const slash = p.indexOf('/');
  if (slash < 0) return { host: p.replace(/^www\./, ''), path: '/' };
  let path = p.slice(slash);
  while (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
  return { host: p.slice(0, slash).replace(/^www\./, ''), path };
}

// "23:14", or "1:02:03" past an hour.
export function clock(seconds) {
  const s = Math.max(0, Math.ceil(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const mm = h > 0 ? String(m).padStart(2, '0') : String(m);
  return (h > 0 ? `${h}:` : '') + `${mm}:${String(sec).padStart(2, '0')}`;
}

// "24m", "1h 5m", "2h" (de "24 Min", az "24 dəq").
export function minutesLabel(seconds) {
  const total = Math.max(0, Math.round(seconds / 60));
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return t('durationMinutes', m);
  return m === 0 ? t('durationHours', h) : t('durationHoursMinutes', h, m);
}

// "1 minute", "2 minutes": for sentences and screen readers.
export function minutesPhrase(seconds) {
  return plural('minutesPhrase', Math.round(seconds / 60));
}

// "4h", "3h 30m", "45m" from minutes.
export function goalLabel(minutes) {
  return minutesLabel(minutes * 60);
}

// "21:40" in the user's own clock style.
export function timeOfDay(ms) {
  return new Date(ms).toLocaleTimeString(uiLanguage(), { hour: 'numeric', minute: '2-digit' });
}

// "21 Oct". Chromium's Intl has no month names for languages its own UI doesn't
// ship (Azerbaijani comes out as "M10 21"), so those get digits: "21.10".
export function dayAndMonth(ms) {
  const date = new Date(ms);
  const text = date.toLocaleDateString(uiLanguage(), { day: 'numeric', month: 'short' });
  return /^M\d/.test(text) ? `${date.getDate()}.${String(date.getMonth() + 1).padStart(2, '0')}` : text;
}

// "Last connected today at 18:05", "… yesterday at 9:12", "… on 21 Oct".
export function lastSeen(ms, now = Date.now()) {
  if (!ms) return null;
  const day = (time) => { const d = new Date(time); d.setHours(0, 0, 0, 0); return d.getTime(); };
  const diffDays = Math.round((day(now) - day(ms)) / 86400000);
  if (diffDays === 0) return t('popupLastConnectedToday', timeOfDay(ms));
  if (diffDays === 1) return t('popupLastConnectedYesterday', timeOfDay(ms));
  return t('popupLastConnectedOn', dayAndMonth(ms));
}

// First letter for a site's tile, e.g. "x.com" → "X".
export function tileLetter(host) {
  const name = String(host || '?').replace(/^www\./, '');
  return (name[0] || '?').toUpperCase();
}

// "x.com", "x.com and reddit.com", "x.com, reddit.com and 4 more"
export function listSummary(items) {
  if (items.length === 0) return '';
  if (items.length === 1) return items[0];
  if (items.length === 2) return t('listTwo', items[0], items[1]);
  return t('listMore', items[0], items[1], items.length - 2);
}
