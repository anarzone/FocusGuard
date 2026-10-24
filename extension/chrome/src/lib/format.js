// Small pure helpers for addresses and times. No chrome.* here, so the
// tests can run them in Node.

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

// "24m", "1h 5m", "2h".
export function minutesLabel(seconds) {
  const total = Math.max(0, Math.round(seconds / 60));
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return `${m}m`;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

// "4h", "3h 30m", "45m" from minutes.
export function goalLabel(minutes) {
  return minutesLabel(minutes * 60);
}

// "21:40" in the user's own clock style.
export function timeOfDay(ms, locale) {
  return new Date(ms).toLocaleTimeString(locale, { hour: 'numeric', minute: '2-digit' });
}

// "today at 18:05", "yesterday at 9:12", "on 21 Oct".
export function lastSeen(ms, now = Date.now(), locale) {
  if (!ms) return null;
  const day = (t) => { const d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); };
  const diffDays = Math.round((day(now) - day(ms)) / 86400000);
  if (diffDays === 0) return `today at ${timeOfDay(ms, locale)}`;
  if (diffDays === 1) return `yesterday at ${timeOfDay(ms, locale)}`;
  return `on ${new Date(ms).toLocaleDateString(locale, { day: 'numeric', month: 'short' })}`;
}

// 1 → "1st", 3 → "3rd", 11 → "11th".
export function ordinal(n) {
  const mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 13) return `${n}th`;
  return n + ({ 1: 'st', 2: 'nd', 3: 'rd' }[n % 10] || 'th');
}

// First letter for a site's tile, e.g. "x.com" → "X".
export function tileLetter(host) {
  const name = String(host || '?').replace(/^www\./, '');
  return (name[0] || '?').toUpperCase();
}

// "x.com, reddit.com and 4 more"
export function listSummary(items, shown = 2) {
  if (items.length === 0) return '';
  if (items.length <= shown) {
    return items.length === 1 ? items[0] : `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
  }
  return `${items.slice(0, shown).join(', ')} and ${items.length - shown} more`;
}
