// Pro blocking: which addresses are blocked right now, and the
// declarativeNetRequest rules that keep them from loading. Pure functions of
// the app's state, so they're tested in Node.

import { displayHost, hostname, splitPart, withoutRootDot } from './format.js';

function bareHost(host) {
  return withoutRootDot(String(host).toLowerCase()).replace(/^www\./, '');
}

// A site rule covers the site and its subdomains, like the app's Classifier.
export function hostMatches(host, site) {
  if (!host || !site) return false;
  const h = bareHost(host);
  const s = bareHost(site);
  return h === s || h.endsWith(`.${s}`);
}

// The path as a server reads it: /%73horts//abc is /shorts/abc.
export function plainPath(path) {
  return path
    .replace(/%([0-9a-f]{2})/gi, (whole, hex) => (parseInt(hex, 16) < 128 ? String.fromCharCode(parseInt(hex, 16)) : whole))
    .replace(/\/{2,}/g, '/')
    .toLowerCase();
}

// "youtube.com/shorts" covers /shorts and /shorts/abc, not /shortsale.
export function partMatches(url, pattern) {
  let u;
  try { u = new URL(url); } catch { return false; }
  const { host, path } = splitPart(pattern);
  if (!hostMatches(u.hostname, host)) return false;
  if (path === '/') return true;
  const p = plainPath(u.pathname);
  return p === path || p.startsWith(`${path}/`);
}

// A pass or "for work" covers the host it was taken on and that host's
// subdomains, with or without "www.". It never reaches up: one on m.x.com
// leaves x.com blocked, and one on x.com covers m.x.com.
function excusedHosts(state, now) {
  const passes = (state.blocking?.passes || []).filter((p) => p.until > now).map((p) => p.host);
  return [...passes, ...(state.blocking?.allowed || [])];
}

function excused(url, state, now) {
  const host = hostname(url);
  return excusedHosts(state, now).some((h) => hostMatches(host, h));
}

// The Pro features the app says are unlocked.
export function features(state) {
  return state?.plan?.features || {};
}

// Blocking applies while a session runs (not paused, not on a break), and
// daily limits all day.
export function sessionBlocking(state) {
  return state?.phase === 'focusing' && !!features(state).blockInBrowser;
}

// Why `url` is blocked right now: { kind: 'limit'|'part'|'site', target },
// or null. Limits win: they hold outside sessions too.
export function blockReason(url, state, now = Date.now()) {
  if (!features(state).blockInBrowser) return null;
  const host = displayHost(url);
  if (!host) return null;
  const b = state.blocking || {};
  for (const limit of b.limits || []) {
    if (limit.reached && hostMatches(host, limit.site)) return { kind: 'limit', target: limit.site };
  }
  if (!sessionBlocking(state) || excused(url, state, now)) return null;
  for (const part of features(state).partsOfSites ? b.parts || [] : []) {
    if (partMatches(url, part)) return { kind: 'part', target: part };
  }
  for (const site of b.sites || []) {
    if (hostMatches(host, site)) return { kind: 'site', target: site };
  }
  return null;
}

export function escapeRegex(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// RE2 for declarativeNetRequest, anchored on the whole address.
export function siteRegex(site) {
  return `^https?://([^/?#@]*\\.)?${escapeRegex(site.toLowerCase())}\\.?(:[0-9]+)?([/?#].*)?$`;
}

export function partRegex(pattern) {
  const { host, path } = splitPart(pattern);
  // Doubled slashes too. An escaped path is left to the matchers, which catch
  // it as the page opens: a rule for every way to escape every letter is too big.
  const pathPart = path === '/' ? '' : escapeRegex(path).replace(/\//g, '/+');
  return `^https?://([^/?#@]*\\.)?${escapeRegex(host)}\\.?(:[0-9]+)?${pathPart}([/?#].*)?$`;
}

// The block page, with what was blocked; the original address follows the
// "#" so it never has to be escaped.
export function blockPageSubstitution(blockPage, kind, target) {
  return `${blockPage}?kind=${kind}&target=${encodeURIComponent(target)}#\\0`;
}

// The session rules for this state: one redirect per blocked site, part or
// reached limit, minus passes and "for work" sites. An excuse on a host inside
// a blocked site can't remove the site's rule, so it gets an allow rule above it.
// Limits go above those: nothing excuses a limit.
export function buildRules(state, blockPage, now = Date.now()) {
  if (!features(state).blockInBrowser) return [];
  const b = state.blocking || {};
  const excuses = excusedHosts(state, now);
  const isExcused = (site) => excuses.some((h) => hostMatches(site, h));

  const rules = [];
  const push = (action, regexFilter, priority) => {
    rules.push({
      id: rules.length + 1,
      priority,
      action,
      condition: { regexFilter, resourceTypes: ['main_frame'], isUrlFilterCaseSensitive: false },
    });
  };
  const add = (kind, target, regexFilter, priority) => {
    push({ type: 'redirect', redirect: { regexSubstitution: blockPageSubstitution(blockPage, kind, target) } }, regexFilter, priority);
  };

  for (const limit of b.limits || []) {
    if (limit.reached) add('limit', limit.site, siteRegex(limit.site), 4);
  }
  if (sessionBlocking(state)) {
    const parts = features(state).partsOfSites ? b.parts || [] : [];
    const sites = b.sites || [];
    const blockedHosts = [...parts.map((part) => splitPart(part).host), ...sites];
    const inside = new Set(excuses.map(bareHost).filter((h) => blockedHosts.some((s) => hostMatches(h, s) && !hostMatches(s, h))));
    for (const host of inside) push({ type: 'allow' }, siteRegex(host), 3);
    for (const part of parts) {
      if (!isExcused(splitPart(part).host)) add('part', part, partRegex(part), 2);
    }
    for (const site of sites) {
      if (!isExcused(site)) add('site', site, siteRegex(site), 1);
    }
  }
  return rules;
}

// Same rules, ignoring ids, so the background only updates on a change.
export function rulesKey(rules) {
  return JSON.stringify(rules.map(({ id, ...rest }) => rest));
}
