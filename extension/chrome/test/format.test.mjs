import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  clock, displayHost, goalLabel, hostname, listSummary, minutesLabel, ordinal, pagePattern, splitPart, tileLetter,
} from '../src/lib/format.js';

test('displayHost keeps web hosts and drops www', () => {
  assert.equal(displayHost('https://www.x.com/home'), 'x.com');
  assert.equal(displayHost('http://News.YCombinator.com/item?id=1'), 'news.ycombinator.com');
  assert.equal(displayHost('chrome://newtab/'), null);
  assert.equal(displayHost('chrome-extension://abc/pages/block.html'), null);
  assert.equal(displayHost('not a url'), null);
  assert.equal(hostname('https://www.x.com/'), 'www.x.com');
});

test('pagePattern is host and path without query, fragment or trailing slash', () => {
  assert.equal(pagePattern('https://medium.com/@ann/structured-concurrency-123?source=x#top'), 'medium.com/@ann/structured-concurrency-123');
  assert.equal(pagePattern('https://www.youtube.com/shorts/'), 'youtube.com/shorts');
  assert.equal(pagePattern('https://x.com/'), null);
  assert.equal(pagePattern('file:///tmp/a.html'), null);
});

test('splitPart separates host and path', () => {
  assert.deepEqual(splitPart('youtube.com/shorts'), { host: 'youtube.com', path: '/shorts' });
  assert.deepEqual(splitPart('https://www.LinkedIn.com/feed/'), { host: 'linkedin.com', path: '/feed' });
  assert.deepEqual(splitPart('reddit.com'), { host: 'reddit.com', path: '/' });
});

test('clock counts down in m:ss, with hours past an hour', () => {
  assert.equal(clock(23 * 60 + 14), '23:14');
  assert.equal(clock(59.2), '1:00');
  assert.equal(clock(0), '0:00');
  assert.equal(clock(-5), '0:00');
  assert.equal(clock(3723), '1:02:03');
});

test('minute labels', () => {
  assert.equal(minutesLabel(24 * 60), '24m');
  assert.equal(minutesLabel(2 * 3600 + 48 * 60), '2h 48m');
  assert.equal(minutesLabel(7200), '2h');
  assert.equal(goalLabel(240), '4h');
  assert.equal(goalLabel(210), '3h 30m');
});

test('ordinals, tiles and list summaries', () => {
  assert.deepEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101].map(ordinal),
    ['1st', '2nd', '3rd', '4th', '11th', '12th', '13th', '21st', '22nd', '23rd', '101st']);
  assert.equal(tileLetter('www.medium.com'), 'M');
  assert.equal(listSummary(['x.com']), 'x.com');
  assert.equal(listSummary(['x.com', 'reddit.com']), 'x.com and reddit.com');
  assert.equal(listSummary(['x.com', 'reddit.com', 'a.com', 'b.com', 'c.com', 'd.com']), 'x.com, reddit.com and 4 more');
});

test('paused page fields read the way paused.html reads them', async () => {
  const { parseFragment, safeWebURL } = await import('../src/lib/format.js');
  assert.deepEqual(parseFragment('#id=abc-1&host=x.com&url=https%3A%2F%2Fx.com%2Fhome%3Fa%3D1&state=queued&ends=2000&back=Visual%20Studio%20Code'), {
    id: 'abc-1', host: 'x.com', url: 'https://x.com/home?a=1', state: 'queued', ends: '2000', back: 'Visual Studio Code',
  });
  assert.deepEqual(parseFragment('id=a&bad=%E0%A4%A&x'), { id: 'a', x: '' });
  assert.equal(safeWebURL('https://x.com/home'), 'https://x.com/home');
  assert.equal(safeWebURL('javascript:alert(1)'), null);
  assert.equal(safeWebURL('file:///etc/passwd'), null);
});
