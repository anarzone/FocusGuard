import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { blockReason, buildRules, hostMatches, partMatches, partRegex, rulesKey, siteRegex } from '../src/lib/blocking.js';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/state-focusing.json', import.meta.url)));
const asOf = fixture.session.asOf;
const free = { ...fixture, plan: { tier: 'free', pro: false } };
const BLOCK = 'chrome-extension://abeehapgjhkgbfokheomoahlgidgcoik/pages/block.html';

test('site rules cover subdomains, not look-alikes', () => {
  assert.ok(hostMatches('x.com', 'x.com'));
  assert.ok(hostMatches('www.x.com', 'x.com'));
  assert.ok(hostMatches('old.reddit.com', 'reddit.com'));
  assert.ok(!hostMatches('notx.com', 'x.com'));
  assert.ok(!hostMatches('x.com.evil.net', 'x.com'));
});

test('parts of sites match whole path segments', () => {
  assert.ok(partMatches('https://www.youtube.com/shorts', 'youtube.com/shorts'));
  assert.ok(partMatches('https://m.youtube.com/shorts/abc?x=1', 'youtube.com/shorts'));
  assert.ok(!partMatches('https://youtube.com/shortsale', 'youtube.com/shorts'));
  assert.ok(!partMatches('https://youtube.com/watch?v=1', 'youtube.com/shorts'));
  assert.ok(partMatches('https://www.linkedin.com/feed/', 'linkedin.com/feed'));
});

test('free plans never block in the browser', () => {
  assert.equal(blockReason('https://reddit.com/', free, asOf), null);
  assert.deepEqual(buildRules(free, BLOCK, asOf), []);
});

test('pro blocks sites and parts while focusing, minus passes and for-work sites', () => {
  assert.deepEqual(blockReason('https://old.reddit.com/r/swift', fixture, asOf), { kind: 'site', target: 'reddit.com' });
  assert.deepEqual(blockReason('https://www.youtube.com/shorts/abc', fixture, asOf), { kind: 'part', target: 'youtube.com/shorts' });
  assert.equal(blockReason('https://www.youtube.com/watch?v=1', fixture, asOf), null);
  // x.com has a running pass until asOf + 80 s.
  assert.equal(blockReason('https://x.com/home', fixture, asOf), null);
  assert.deepEqual(blockReason('https://x.com/home', fixture, asOf + 81_000), { kind: 'site', target: 'x.com' });
  assert.equal(blockReason('https://github.com/', fixture, asOf), null);
});

test('each Pro feature unlocks its own part', () => {
  const noParts = { ...fixture, plan: { ...fixture.plan, features: { ...fixture.plan.features, partsOfSites: false } } };
  assert.equal(blockReason('https://www.youtube.com/shorts/abc', noParts, asOf), null);
  assert.deepEqual(blockReason('https://reddit.com/', noParts, asOf), { kind: 'site', target: 'reddit.com' });
  assert.equal(buildRules(noParts, BLOCK, asOf).filter((r) => r.action.redirect.regexSubstitution.includes('kind=part')).length, 0);
  const noBrowser = { ...fixture, plan: { ...fixture.plan, features: { ...fixture.plan.features, blockInBrowser: false } } };
  assert.deepEqual(buildRules(noBrowser, BLOCK, asOf), []);
});

test('nothing but limits blocks outside a running session', () => {
  const onBreak = { ...fixture, phase: 'break' };
  assert.equal(blockReason('https://reddit.com/', onBreak, asOf), null);
  const limited = { ...onBreak, blocking: { ...fixture.blocking, limits: [{ site: 'reddit.com', minutes: 30, usedSeconds: 1800, reached: true, extraLeft: 1 }] } };
  assert.deepEqual(blockReason('https://reddit.com/', limited, asOf), { kind: 'limit', target: 'reddit.com' });
  assert.deepEqual(buildRules(limited, BLOCK, asOf).map((r) => r.action.redirect.regexSubstitution),
    [`${BLOCK}?kind=limit&target=reddit.com#\\0`]);
});

test('rules redirect main frames to the block page with the address after #', () => {
  const rules = buildRules(fixture, BLOCK, asOf);
  // Two parts and three sites (x.com has a pass).
  assert.equal(rules.length, 5);
  assert.deepEqual(rules.map((r) => r.id), [1, 2, 3, 4, 5]);
  for (const rule of rules) {
    assert.equal(rule.action.type, 'redirect');
    assert.deepEqual(rule.condition.resourceTypes, ['main_frame']);
    assert.equal(rule.condition.isUrlFilterCaseSensitive, false);
    assert.match(rule.action.redirect.regexSubstitution, /#\\0$/);
  }
  assert.ok(!rules.some((r) => r.action.redirect.regexSubstitution.includes('target=x.com')));
  assert.equal(rulesKey(rules), rulesKey(buildRules(fixture, BLOCK, asOf)));
});

test('rule regexes match the same addresses as the matchers', () => {
  const site = new RegExp(siteRegex('reddit.com'), 'i');
  assert.ok(site.test('https://reddit.com'));
  assert.ok(site.test('https://www.reddit.com/r/swift?sort=new'));
  assert.ok(site.test('http://old.reddit.com:8080/'));
  assert.ok(!site.test('https://notreddit.com/'));
  assert.ok(!site.test('https://reddit.com.evil.net/'));
  assert.ok(!site.test('https://evil.net/?u=https://reddit.com/'));

  const part = new RegExp(partRegex('youtube.com/shorts'), 'i');
  assert.ok(part.test('https://www.youtube.com/shorts'));
  assert.ok(part.test('https://youtube.com/shorts/abc'));
  assert.ok(part.test('https://youtube.com/Shorts?feature=share'));
  assert.ok(!part.test('https://youtube.com/shortsale'));
  assert.ok(!part.test('https://youtube.com/watch?v=shorts'));
});
