// Pro blocking: which addresses are blocked right now, and the
// declarativeNetRequest rules that keep them from loading. Pure functions of
// the app's state, so they're tested in Node.

import { displayHost, hostname, splitPart } from './format.js';

// A site rule covers the site and its subdomains, like the app's Classifier.
export function hostMatches(host, site) {
  if (!host || !site) return false;
  const h = host.toLowerCase().replace(/^www\./, '');
  const s = site.toLowerCase().replace(/^www\./, '');
  return h === s || h.endsWith(`.${s}`);
}

// "youtube.com/shorts" covers /shorts and /shorts/abc, not /shortsale.
export function partMatches(url, pattern) {
  let u;
  try { u = new URL(url); } catch { return false; }
  const { host, path } = splitPart(pattern);
  if (!hostMatches(u.hostname, host)) return false;
  if (path === '/') return true;
  const p = u.pathname.toLowerCase();
  return p === path || p.startsWith(`${path}/`);
}

// A pass or "for work" on one host lets through the rule it hit.
function excused(url, state, now) {
  const host = hostname(url);
  const passes = (state.blocking?.passes || []).filter((p) => p.until > now).map((p) => p.host);
  const allowed = state.blocking?.allowed || [];
  return [...passes, ...allowed].some((h) => hostMatches(host, h) || hostMatches(h, host));
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
  return `^https?://([^/?#@]*\\.)?${escapeRegex(site.toLowerCase())}(:[0-9]+)?([/?#].*)?$`;
}

export function partRegex(pattern) {
  const { host, path } = splitPart(pattern);
  const pathPart = path === '/' ? '' : escapeRegex(path);
  return `^https?://([^/?#@]*\\.)?${escapeRegex(host)}(:[0-9]+)?${pathPart}([/?#].*)?$`;
}

// The block page, with what was blocked; the original address follows the
// "#" so it never has to be escaped.
export function blockPageSubstitution(blockPage, kind, target) {
  return `${blockPage}?kind=${kind}&target=${encodeURIComponent(target)}#\\0`;
}

// The session rules for this state: one redirect per blocked site, part or
// reached limit, minus passes and "for work" sites.
export function buildRules(state, blockPage, now = Date.now()) {
  if (!features(state).blockInBrowser) return [];
  const b = state.blocking || {};
  const passes = (b.passes || []).filter((p) => p.until > now).map((p) => p.host);
  const excusedHosts = [...passes, ...(b.allowed || [])];
  const isExcused = (site) => excusedHosts.some((h) => hostMatches(h, site) || hostMatches(site, h));

  const rules = [];
  const add = (kind, target, regexFilter, priority) => {
    rules.push({
      id: rules.length + 1,
      priority,
      action: { type: 'redirect', redirect: { regexSubstitution: blockPageSubstitution(blockPage, kind, target) } },
      condition: { regexFilter, resourceTypes: ['main_frame'], isUrlFilterCaseSensitive: false },
    });
  };

  for (const limit of b.limits || []) {
    if (limit.reached) add('limit', limit.site, siteRegex(limit.site), 3);
  }
  if (sessionBlocking(state)) {
    for (const part of features(state).partsOfSites ? b.parts || [] : []) {
      if (!isExcused(splitPart(part).host)) add('part', part, partRegex(part), 2);
    }
    for (const site of b.sites || []) {
      if (!isExcused(site)) add('site', site, siteRegex(site), 1);
    }
  }
  return rules;
}

// Same rules, ignoring ids, so the background only updates on a change.
export function rulesKey(rules) {
  return JSON.stringify(rules.map(({ id, ...rest }) => rest));
}
