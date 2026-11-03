#!/usr/bin/env node
// End-to-end tests of the extension in a real browser, against a fake app and
// a local web server that answers for every host name (see e2e-harness.mjs).
//
//   npm i puppeteer-core                      (anywhere, then run from there)
//   node /path/to/extension/chrome/scripts/e2e.mjs --chrome "/path/to/Chrome"
//
// Options: --chrome PATH   default: Google Chrome in /Applications. Chrome for
//                          Testing works too (npx @puppeteer/browsers install chrome@stable)
//          --group REGEX   run only the groups whose name matches
//          --only REGEX    run only the tests whose name matches
//          --helper PATH   use this native host instead of the stand-in. Only a
//                          copy that can't reach the real app: the socket
//                          variable is the only thing keeping a stock helper
//                          off the running FocusGuard
//          --out DIR       screenshots (default: ./e2e-shots)
//          --list          print the names and stop
//
// It never touches a real profile or the running app: the browser gets a temp
// profile with its own host manifest, and every address resolves to localhost.
//
// The extension loads through the same pipe as smoke.mjs. Two groups need it to
// stay installed over a restart, which only --load-extension does, so they need
// Chrome for Testing: branded Chrome ignores that flag.
//
// A test marked `bug` asserts the right behaviour and is known to fail today.
// It prints KNOWN and doesn't fail the run; once it's fixed it prints FIXED, a
// reminder to take the mark off. Anything else that fails fails the run.

import fs from 'node:fs';
import path from 'node:path';

import {
  EXTENSION, FREE, FakeApp, ORIGIN, PRO, TRIAL, TestBrowser, Web, loadPuppeteer, makeCert, sleep, tempDir, until,
} from './e2e-harness.mjs';

const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const CHROME = arg('--chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
const ONLY = arg('--only') ? new RegExp(arg('--only'), 'i') : null;
const GROUP = arg('--group') ? new RegExp(arg('--group'), 'i') : null;
const HELPER = arg('--helper');
const OUT = path.resolve(arg('--out', 'e2e-shots'));
const LIST = args.includes('--list');

const BLOCK = `${ORIGIN}/pages/block.html`;
const REDDIT_LIMIT = (over = {}) => ({ site: 'reddit.com', minutes: 30, usedSeconds: 1800, reached: true, extraLeft: 1, visits: 6, lastVisitAt: Date.now() - 3600000, ...over });

// ---------------------------------------------------------------------------
// Running

const results = [];
const groups = [];
const group = (name, options, body) => groups.push({ name, options, body });

let puppeteer;
let tmp;
let web;

// One app and browser per group, so nothing carries over.
async function runGroup({ name, options, body }) {
  console.log(`\n${name}`);
  if (options.skip) { console.log('  skipped: needs Chrome for Testing'); return; }
  const app = new FakeApp(path.join(tmp, `app-${groups.findIndex((g) => g.name === name)}.sock`));
  if (options.appRunning !== false) await app.start();
  const browserOptions = { ...options.browser };
  if (browserOptions.extensionDir === 'NO_AZ') {
    // The extension as it ships, less its Azerbaijani catalog.
    browserOptions.extensionDir = fs.mkdtempSync(path.join(tmp, 'ext-'));
    fs.cpSync(EXTENSION, browserOptions.extensionDir, { recursive: true });
    fs.rmSync(path.join(browserOptions.extensionDir, 'i18n', 'az.json'));
  }
  const tb = new TestBrowser({ puppeteer, chrome: CHROME, web, tmp, app, helper: HELPER, ...browserOptions });
  await tb.open();
  if (options.siteAccess !== false) await tb.grantSiteAccess();
  const it = async (label, testOptions, fn) => {
    const test = fn || testOptions;
    const { bug = null } = fn ? testOptions : {};
    if (ONLY && !ONLY.test(label)) return;
    if (LIST) { console.log(`  ${label}`); return; }
    const opened = new Set(await tb.browser.pages());
    try {
      // A hung browser call fails its test, not the whole run.
      let timer;
      await Promise.race([test(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('the test hung for 90 s')), 90000); })]);
      clearTimeout(timer);
      results.push(bug ? ['FIXED', name, label, bug] : ['PASS', name, label]);
      console.log(`  ${bug ? 'FIXED' : 'PASS '} ${label}${bug ? ` (was ${bug})` : ''}`);
    } catch (error) {
      results.push(bug ? ['KNOWN', name, label, bug] : ['FAIL', name, label, error.message]);
      console.log(`  ${bug ? 'KNOWN' : 'FAIL '} ${label}${bug ? ` (${bug})` : ''}: ${error.message}`);
    }
    for (const page of await tb.browser.pages()) {
      if (!opened.has(page) && page !== tb.ctl) await page.close().catch(() => {});
    }
  };
  try {
    await body({ app, tb, it });
  } catch (error) {
    results.push(['FAIL', name, '(group)', error.message]);
    console.log(`  FAIL  the group stopped: ${error.message}`);
  } finally {
    await tb.close();
    await app.stop();
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

// ---------------------------------------------------------------------------
// Pages

const isBlock = (page) => page.url().startsWith(BLOCK);

async function waitBlocked(page, timeout = 5000) {
  await until(`${page.url()} to become the block page`, () => isBlock(page), timeout, 50);
  await page.waitForSelector('#app *', { timeout: 5000 }).catch(() => {});
}

async function waitAt(page, url, timeout = 5000) {
  await until(`the tab to reach ${url} (it's at ${page.url()})`, () => page.url() === url, timeout, 50);
}

// The text of a message, in the page's language.
// The Azerbaijani catalog loads as the page opens, so make sure of it first.
const message = (page, key, ...values) => page.evaluate(async (k, v) => {
  const { loadLanguage, t } = await import('/src/lib/i18n.js');
  await loadLanguage();
  return t(k, ...v);
}, key, values);

// The button with this message as its text (or, while it's waiting, in its label).
// A state arriving mid-click rebuilds the page, so clicks go through this.
async function press(page, key, ...values) {
  await until(`a press on ${key}`, async () => {
    const button = await buttonFor(page, key, ...values);
    if (!button) return false;
    await button.click();
    return true;
  }, 4000);
}

async function buttonFor(page, key, ...values) {
  const text = await message(page, key, ...values);
  const handle = await page.evaluateHandle((wanted) => [...document.querySelectorAll('button, a')]
    .find((el) => el.textContent.includes(wanted) || (el.getAttribute('aria-label') || '').includes(wanted)) || null, text);
  return handle.asElement();
}

const buttonTexts = (page) => page.evaluate(() => [...document.querySelectorAll('.actions button')].map((b) => ({ text: b.textContent.trim(), label: b.getAttribute('aria-label'), disabled: b.disabled })));
const pageText = (page) => page.evaluate(() => document.body.innerText);
const hasPill = (page) => page.evaluate(() => !!document.getElementById('focusguard-pass')).catch(() => false);

// What the pill says. Its shadow root is closed, so only the protocol can see in.
async function pillText(page) {
  const client = await page.createCDPSession();
  try {
    const { root } = await client.send('DOM.getDocument', { depth: -1, pierce: true });
    const parts = [];
    const walk = (node, inside) => {
      const isPill = inside || node.attributes?.includes('focusguard-pass');
      if (isPill && node.nodeType === 3 && node.nodeValue.trim() && node.parentId && !/^\s*:host/.test(node.nodeValue)) parts.push(node.nodeValue.trim());
      for (const child of [...(node.children || []), ...(node.shadowRoots || [])]) walk(child, isPill);
    };
    walk(root, false);
    return parts.join(' | ');
  } finally {
    await client.detach();
  }
}

async function popup(tb, { width = 340, height = 700 } = {}) {
  const page = await tb.browser.newPage();
  await page.setViewport({ width, height });
  await page.goto(`${ORIGIN}/pages/popup.html`);
  return page;
}

// Best effort: a tab behind others can hang a screenshot, so it comes to the front first.
async function shot(page, name) {
  fs.mkdirSync(OUT, { recursive: true });
  await page.bringToFront();
  await Promise.race([page.screenshot({ path: path.join(OUT, `${name}.png`) }), sleep(10000)]);
}

// Reports the app has heard for this address.
const reportsOf = (app, url) => app.messages('tab').filter((m) => m.tab?.url === url);
const lastReport = (app) => app.messages('tab').at(-1)?.tab;

// Text problems a language can have: raw __MSG_ tokens, unfilled $1s, message keys.
const badWords = (page) => page.evaluate(() => {
  const found = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const text = walker.currentNode.nodeValue.trim();
    if (!text) continue;
    if (/__MSG_|\$\d|\$[a-z]+\$|undefined|\bNaN\b|null/.test(text)) found.push(text);
    if (/^[a-z]+[A-Z][A-Za-z]+$/.test(text)) found.push(text);
  }
  return found;
});

// Text cut off or running out of the page.
const clipped = (page) => page.evaluate(() => {
  const out = [];
  const width = document.documentElement.clientWidth;
  for (const el of document.querySelectorAll('body *')) {
    if (!el.childNodes.length || el.closest('svg')) continue;
    const hasText = [...el.childNodes].some((n) => n.nodeType === 3 && n.nodeValue.trim());
    if (!hasText) continue;
    const style = getComputedStyle(el);
    const box = el.getBoundingClientRect();
    if (box.width === 0) continue;
    if (box.right > width + 1 || box.left < -1) out.push(`off the page: ${el.textContent.trim().slice(0, 60)}`);
    else if (el.scrollWidth > el.clientWidth + 1 && style.overflowX !== 'visible' && style.textOverflow !== 'ellipsis' && style.display !== 'inline') out.push(`clipped: ${el.textContent.trim().slice(0, 60)}`);
    else if (el.tagName === 'BUTTON' && el.scrollWidth > el.clientWidth + 1) out.push(`button overflows: ${el.textContent.trim().slice(0, 60)}`);
  }
  return out;
});

// ---------------------------------------------------------------------------
// 1. Install and first run

group('first run: helper missing', { browser: { helperMissing: true }, appRunning: false, siteAccess: false }, async ({ tb, app, it }) => {
  const target = await tb.browser.waitForTarget((t) => t.url().endsWith('pages/welcome.html'), { timeout: 10000 });
  const page = await target.asPage();
  await it('the welcome page opens and says the app is not on this Mac', async () => {
    await page.waitForSelector('button.big-btn');
    await page.click('button.big-btn');
    const title = await message(page, 'welcomeNotOnMacTitle');
    await until('the not-installed step', async () => (await pageText(page)).includes(title));
    await shot(page, 'first-missing-helper');
  });
  await it('the popup asks to get the app', async () => {
    const view = await popup(tb);
    const title = await message(view, 'popupGetAppTitle');
    await until('the get-the-app card', async () => (await pageText(view)).includes(title));
    await shot(view, 'popup-not-installed');
  });
  await it('with no host, no rules and pages load', async () => {
    assertEqual((await tb.rules()).length, 0, 'rules');
    const site = await tb.tab('https://x.com/');
    assertEqual(site.url(), 'https://x.com/', 'the page');
  });
  void app;
});

group('first run: app closed, then opened', { appRunning: false, siteAccess: false }, async ({ tb, app, it }) => {
  const target = await tb.browser.waitForTarget((t) => t.url().endsWith('pages/welcome.html'), { timeout: 10000 });
  const welcome = await target.asPage();
  await it('the welcome page waits for the app', async () => {
    await welcome.waitForSelector('button.big-btn');
    await welcome.click('button.big-btn');
    const title = await message(welcome, 'welcomeNotOpenTitle');
    await until('the not-open step', async () => (await pageText(welcome)).includes(title));
  });
  await it('the popup says the app is not running', async () => {
    const page = await popup(tb);
    const title = await message(page, 'appNotRunning');
    await until('the not-running card', async () => (await pageText(page)).includes(title));
    await shot(page, 'popup-not-running');
    await page.close();
  });
  await it('opening the app moves the welcome page on by itself', async () => {
    await app.start();
    // Headless Chrome counts every extension as pinned, so the pin step may be skipped.
    const pin = await message(welcome, 'welcomePinTitle');
    const done = await message(welcome, 'welcomeDoneTitle');
    await until('the next step', async () => { const text = await pageText(welcome); return text.includes(pin) || text.includes(done); }, 15000);
    await shot(welcome, 'first-pin');
    const skip = await buttonFor(welcome, 'welcomeSkip');
    if (skip) await skip.click();
    await until('the done step', async () => (await pageText(welcome)).includes(done));
    await shot(welcome, 'first-done');
  });
  await it('Pro without site access: the done step offers it, nothing is blocked', async () => {
    app.set({ plan: PRO });
    const allow = await message(welcome, 'welcomeNeedsAccess');
    await until('the site access line', async () => (await pageText(welcome)).includes(allow));
    app.startSession({ preset: 'standard', sites: ['x.com'] });
    await sleep(200);
    assertEqual((await tb.rules()).length, 0, 'rules without site access');
    const page = await tb.tab('https://x.com/');
    assertEqual(page.url(), 'https://x.com/', 'x.com without site access');
    app.endSession();
  });
  await it('adding the extension asks the app for nothing but a hello', async () => {
    const asked = new Set(app.received.map((m) => m.type));
    for (const type of ['helperHello', 'hello', 'tab', 'blockedVisit']) asked.delete(type);
    assertEqual([...asked].join(','), '', 'other messages from first run');
    assertEqual(app.messages('hello')[0].siteAccess, false, 'hello.siteAccess');
  });
  await it('"Allow site access" in the popup turns blocking on and tells the app', async () => {
    app.startSession({ preset: 'standard', sites: ['x.com'] });
    await tb.allowHosts();
    const page = await popup(tb);
    await page.waitForSelector('.plan-card .btn-primary');
    await shot(page, 'popup-needs-site-access');
    await page.click('.plan-card .btn-primary');
    await until('rules', async () => (await tb.rules()).length === 1);
    await until('the app to hear', () => app.messages('hello').at(-1).siteAccess === true);
    await page.waitForSelector('.blocked');
    const blocked = await tb.tab('https://x.com/');
    await waitBlocked(blocked);
  });
  await it('taking site access away in Options stops blocking', async () => {
    app.set({ plan: FREE });
    await until('no rules', async () => (await tb.rules()).length === 0);
    const page = await tb.browser.newPage();
    await page.goto(`${ORIGIN}/pages/options.html`);
    await page.waitForSelector('.panel');
    const remove = await until('the remove link', () => buttonFor(page, 'optionsRemove'));
    await remove.click();
    await until('the app to hear', () => app.messages('hello').at(-1).siteAccess === false);
    app.set({ plan: PRO });
    await sleep(300);
    assertEqual((await tb.rules()).length, 0, 'rules without site access');
    app.endSession();
  });
});

// ---------------------------------------------------------------------------
// 2. The popup in every state

group('popup', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  const web0 = await tb.tab('https://news.test/article/one');
  const sites = ['x.com', 'reddit.com'];
  const states = [
    ['ready, Free', () => { app.set({ plan: FREE, phase: 'ready', session: null }); }, '.start'],
    ['ready, Pro', () => { app.set({ plan: PRO, phase: 'ready', session: null }); }, '.start'],
    ['ready, trial', () => { app.set({ plan: TRIAL, phase: 'ready', session: null }); }, '.start'],
    ['session, Free', () => { app.set({ plan: FREE }); app.startSession({ preset: 'standard', sites, parts: ['youtube.com/shorts'] }); }, '.clock-card'],
    ['session, Pro', () => { app.set({ plan: PRO }); app.startSession({ preset: 'standard', sites, parts: ['youtube.com/shorts'] }); }, '.blocked'],
    ['session, no end', () => { app.startSession({ preset: 'gentle', sites, minutes: null }); }, '.clock-card'],
    ['session, Strict', () => { app.startSession({ preset: 'strict', sites }); }, '.blocked'],
    ['session paused', () => { app.startSession({ preset: 'standard', sites }); app.pauseSession(); }, '.clock-card'],
    ['break', () => { app.startBreak(); }, '.paused-card'],
    ['recap', () => { app.set({ phase: 'complete', session: null, recap: { name: 'Evening focus', endedAt: Date.now() - 1000, showUntil: Date.now() + 60000 } }); }, '.start'],
    ['limit reached', () => { app.set({ phase: 'ready', recap: null, limits: [REDDIT_LIMIT()] }); }, '.start'],
  ];
  for (const [name, arrange, selector] of states) {
    await it(`${name}: renders, with every word filled in`, async () => {
      arrange();
      const page = await popup(tb);
      await page.waitForSelector(selector, { timeout: 5000 });
      await sleep(100);
      const bad = await badWords(page);
      assertEqual(bad.join(' / '), '', 'raw text');
      const cut = await clipped(page);
      assertEqual(cut.join(' / '), '', 'clipped text');
      await shot(page, `popup-${name.replace(/\W+/g, '-')}`);
    });
  }
  app.set({ limits: [], phase: 'ready', session: null, plan: PRO });

  await it('the real toolbar popup shows this tab and changes its category', async () => {
    await web0.bringToFront();
    await tb.sw(() => chrome.action.openPopup());
    const target = await tb.browser.waitForTarget((t) => t.url().endsWith('pages/popup.html'), { timeout: 5000 });
    const page = await target.asPage();
    await page.waitForSelector('.page-card .chip-btn', { timeout: 5000 });
    const text = await pageText(page);
    assert(text.includes('news.test'), `the popup's page card: ${text.slice(0, 200)}`);
    await page.click('.page-card .chip-btn');
    await page.waitForSelector('.menu');
    const distracting = await message(page, 'categoryDistracting');
    const item = (await page.evaluateHandle((w) => [...document.querySelectorAll('.menu button')].find((b) => b.textContent.includes(w)), distracting)).asElement();
    await item.click();
    const sent = await until('setCategory', () => app.messages('setCategory').at(-1));
    assertEqual(sent.scope, 'site', 'scope');
    assertEqual(sent.category, 'distracting', 'category');
    assertEqual(sent.url, 'https://news.test/article/one', 'url');
    await page.close().catch(() => {});
  });

  await it('Strict: the popup does not offer to change a category while the list is locked', async () => {
    app.startSession({ preset: 'strict', sites });
    await web0.bringToFront();
    await tb.sw(() => chrome.action.openPopup());
    const target = await tb.browser.waitForTarget((t) => t.url().endsWith('pages/popup.html'), { timeout: 5000 });
    const page = await target.asPage();
    await page.waitForSelector('.page-card .chip-btn', { timeout: 5000 });
    await sleep(300);
    const before = app.messages('setCategory').length;
    const offered = await page.evaluate(() => !!document.querySelector('.page-card .chip-btn:not([disabled])'));
    await page.evaluate(() => document.querySelector('.page-card .chip-btn').click());
    await sleep(200);
    const menu = await page.evaluate(() => !!document.querySelector('.menu'));
    await shot(page, 'popup-strict-locked');
    await page.close().catch(() => {});
    app.endSession();
    assert(!offered, 'the category menu is live in Strict');
    assert(!menu, 'the category menu opened in Strict');
    assertEqual(app.messages('setCategory').length, before, 'category changes sent');
  });
  await it('Strict with no planned end is locked too, and a session ending unlocks it', async () => {
    app.startSession({ preset: 'strict', sites, minutes: null });
    await web0.bringToFront();
    await tb.sw(() => chrome.action.openPopup());
    const target = await tb.browser.waitForTarget((t) => t.url().endsWith('pages/popup.html'), { timeout: 5000 });
    const page = await target.asPage();
    await page.waitForSelector('.page-card .chip-btn', { timeout: 5000 });
    assert(await page.evaluate(() => document.querySelector('.page-card .chip-btn').disabled), 'live in an open-ended session');
    app.endSession();
    await page.waitForFunction(() => document.querySelector('.page-card .chip-btn:not([disabled])'), { timeout: 5000 });
    await page.close().catch(() => {});
  });

  await it('options shows the plan, lists and saves its switches', async () => {
    app.set({ plan: PRO, sites, parts: ['youtube.com/shorts'], limits: [REDDIT_LIMIT()] });
    const page = await tb.browser.newPage();
    await page.setViewport({ width: 1100, height: 900 });
    await page.goto(`${ORIGIN}/pages/options.html`);
    await page.waitForSelector('.panel');
    const text = await pageText(page);
    for (const wanted of ['x.com', 'reddit.com', 'youtube.com/shorts']) assert(text.includes(wanted), `${wanted} in the list`);
    assertEqual((await badWords(page)).join(' / '), '', 'raw text');
    const toggle = (labelledBy) => page.evaluate((id) => document.querySelector(`[aria-labelledby="${id}"]`).click(), labelledBy);
    await toggle('badge-label');
    await until('badge setting saved', () => page.evaluate(async () => (await chrome.storage.local.get('settings')).settings?.badgeMinutes === true));
    await page.waitForFunction(() => document.querySelector('[aria-labelledby="badge-label"]').getAttribute('aria-checked') === 'true');
    await toggle('yt-label');
    await until('youtube setting saved', () => page.evaluate(async () => (await chrome.storage.local.get('settings')).settings?.youtubePerVideo === false));
    await shot(page, 'options-pro');
    await page.reload();
    await page.waitForSelector('.panel');
    await page.waitForFunction(() => document.querySelector('[aria-labelledby="yt-label"]')?.getAttribute('aria-checked') === 'false');
    await toggle('yt-label');
    await toggle('badge-label');
    app.set({ limits: [] });
  });

  await it('the plan drops to Free in a session: the rules go', async () => {
    app.set({ plan: PRO, limits: [] });
    app.startSession({ preset: 'standard', sites, parts: [] });
    await until('rules on', async () => (await tb.rules()).length === 2);
    app.set({ plan: FREE });
    await until('rules off', async () => (await tb.rules()).length === 0);
    app.set({ plan: PRO });
    app.endSession();
  });
});

// ---------------------------------------------------------------------------
// 3. The block: every way to the same site

group('block: addresses', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  app.startSession({ preset: 'standard', sites: ['x.com', 'distract.test'], parts: ['youtube.com/shorts', 'linkedin.com/feed'] });
  await until('rules', async () => (await tb.rules()).length === 4);
  const go = async (url) => {
    const page = await tb.browser.newPage();
    await page.goto(url, { waitUntil: 'load', timeout: 8000 }).catch(() => {});
    await sleep(250);
    const blocked = isBlock(page);
    const at = page.url();
    await page.close();
    return { blocked, at };
  };
  const mustBlock = [
    'https://x.com/', 'https://www.x.com/', 'https://m.x.com/home', 'http://x.com/', 'https://X.COM/Home', 'https://x.com:8443/',
    'https://x.com?utm=1', 'https://x.com#top', 'http://distract.test/', 'https://a.b.distract.test/deep/path',
    'https://youtube.com/shorts/abc', 'https://www.youtube.com/shorts/abc', 'https://m.youtube.com/shorts/abc',
    'https://youtube.com/shorts', 'https://youtube.com/shorts/', 'https://youtube.com/Shorts/ABC', 'https://youtube.com/shorts?x=1',
    'https://www.linkedin.com/feed/', 'https://linkedin.com/feed/update/1',
  ];
  for (const url of mustBlock) {
    await it(`blocks ${url}`, async () => {
      const { blocked, at } = await go(url);
      assert(blocked, `loaded: ${at}`);
    });
  }
  const mustLoad = [
    'https://notx.com/', 'https://x.com.evil.test/', 'https://evil.test/x.com', 'https://evil.test/?u=https://x.com/',
    'https://youtube.com/', 'https://youtube.com/watch?v=1', 'https://youtube.com/shortsale', 'https://youtube.com/feed/shorts',
    'https://linkedin.com/in/someone', 'https://notyoutube.com/shorts/abc',
  ];
  for (const url of mustLoad) {
    await it(`lets through ${url}`, async () => {
      const { blocked, at } = await go(url);
      assert(!blocked, `blocked: ${at}`);
    });
  }
  // Ways around, the kind a distracted person finds.
  await it('blocks a trailing dot: https://x.com./home', async () => {
    const { blocked, at } = await go('https://x.com./home');
    assert(blocked, `loaded: ${at}`);
  });
  await it('blocks a trailing dot on a part: https://youtube.com./shorts/abc', async () => {
    const { blocked, at } = await go('https://youtube.com./shorts/abc');
    assert(blocked, `loaded: ${at}`);
  });
  await it('a doubled slash on a part never reaches the site', async () => {
    const since = Date.now();
    const { blocked } = await go('https://youtube.com//shorts/never');
    assert(blocked, 'blocked');
    assert(!web.served('youtube.com', since), 'the server saw a request');
  });
  await it('blocks a login in the address before it loads: https://me:pw@x.com/', async () => {
    const since = Date.now();
    const { blocked, at } = await go('https://me:pw@x.com/');
    assert(blocked, `loaded: ${at}`);
    assert(!web.served('x.com', since), 'the site was asked');
  });
  await it('a trailing dot reaches the app as the site it is', async () => {
    const page = await tb.browser.newPage();
    await page.goto('https://x.com./report', { timeout: 5000 }).catch(() => {});
    await waitBlocked(page);
    assert(!web.served('x.com.', Date.now() - 5000), 'the site was asked');
    app.passes.set('x.com', Date.now() + 60000);
    app.push(true);
    await sleep(300);
    await page.goto('https://x.com./report');
    await until('the report', () => reportsOf(app, 'https://x.com/report').length > 0, 3000);
    app.passes.clear();
    app.push(true);
    await sleep(300);
  });
  await it('blocks a doubled slash on a part: https://youtube.com//shorts/abc', async () => {
    const { blocked, at } = await go('https://youtube.com//shorts/abc');
    assert(blocked, `loaded: ${at}`);
  });
  await it('blocks an escaped path on a part: https://youtube.com/%73horts/abc', async () => {
    const { blocked, at } = await go('https://youtube.com/%73horts/abc');
    assert(blocked, `loaded: ${at}`);
  });
  await it('blocks view-source:https://x.com/', async () => {
    const page = await tb.browser.newPage();
    const since = Date.now();
    await page.goto('view-source:https://x.com/', { timeout: 5000 }).catch(() => {});
    await sleep(500);
    assert(isBlock(page) || !web.served('x.com', since), `view-source reached the site: ${page.url()}`);
  });
  await it('blocked before anything loads: the site is never asked', async () => {
    const since = Date.now();
    const { blocked } = await go('https://x.com/never');
    assert(blocked, 'blocked');
    assert(!web.served('x.com', since), 'the server saw a request');
  });
  await it('the original address comes through whole', async () => {
    const page = await tb.browser.newPage();
    await page.goto('https://x.com/a/b?q=1&r=two%20words&s=é#frag', { timeout: 5000 }).catch(() => {});
    await waitBlocked(page);
    const original = await page.evaluate(() => location.hash.slice(1));
    assertEqual(original, 'https://x.com/a/b?q=1&r=two%20words&s=%C3%A9#frag', 'after the #');
  });
});

group('block: getting there', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  const SITES = { preset: 'standard', sites: ['x.com'], parts: ['youtube.com/shorts'] };
  app.startSession(SITES);
  await until('rules', async () => (await tb.rules()).length === 2);

  await it('a server redirect to the site', async () => {
    const page = await tb.tab('https://ok.test/redirect?to=https://x.com/landed');
    await waitBlocked(page);
    assert((await page.evaluate(() => location.hash)).includes('x.com/landed'), 'the landing address');
  });
  await it('a script redirect to the site', async () => {
    const page = await tb.tab('https://ok.test/jsredirect?to=https://x.com/landed');
    await waitBlocked(page);
  });
  await it('a link on another page', async () => {
    const page = await tb.tab('https://ok.test/');
    await page.evaluate(() => { const a = document.createElement('a'); a.href = 'https://x.com/link'; a.id = 'go'; a.textContent = 'go'; document.body.prepend(a); });
    await page.click('#go');
    await waitBlocked(page);
  });
  await it('window.open from another page', async () => {
    const page = await tb.tab('https://ok.test/');
    const popped = new Promise((resolve) => tb.browser.once('targetcreated', resolve));
    await page.evaluate(() => { window.open('https://x.com/popped'); });
    const target = await popped;
    const opened = await target.asPage();
    await waitBlocked(opened);
    await opened.close();
  });
  await it('reload on the block page stays blocked', async () => {
    const page = await tb.tab('https://x.com/');
    await waitBlocked(page);
    const at = page.url();
    await page.reload();
    await sleep(200);
    assertEqual(page.url(), at, 'after reload');
  });
  await it('a second tab is blocked too', async () => {
    const one = await tb.tab('https://x.com/1');
    const two = await tb.tab('https://x.com/2');
    await waitBlocked(one);
    await waitBlocked(two);
  });
  await it('the back button returns to the page before, not the site', async () => {
    const page = await tb.tab('https://ok.test/before');
    await page.goto('https://x.com/').catch(() => {});
    await waitBlocked(page);
    await page.goBack().catch(() => {});
    await waitAt(page, 'https://ok.test/before');
    await page.goForward().catch(() => {});
    await waitBlocked(page);
  });
  await it('typing the block page\'s own address with another site does nothing for the app\'s list', async () => {
    // Opening block.html directly isn't a way through: its buttons still ask the app.
    const page = await tb.tab(`${BLOCK}?kind=site&target=notblocked.test#https://notblocked.test/`);
    await page.waitForSelector('.actions button');
    assert(isBlock(page), 'the page itself');
  });
  await it('a page open before the session goes to the block page when it starts', async () => {
    app.endSession();
    await until('rules off', async () => (await tb.rules()).length === 0);
    const page = await tb.tab('https://x.com/open-before');
    assertEqual(page.url(), 'https://x.com/open-before', 'before the session');
    app.startSession(SITES);
    await waitBlocked(page);
    assert((await page.evaluate(() => location.hash)).includes('open-before'), 'the address it was on');
  });
  await it('a tab behind, open before the session, is blocked when it comes to the front', async () => {
    app.endSession();
    await until('rules off', async () => (await tb.rules()).length === 0);
    const behind = await tb.tab('https://x.com/behind');
    const front = await tb.tab('https://ok.test/front');
    app.startSession(SITES);
    await sleep(600);
    assertEqual(behind.url(), 'https://x.com/behind', 'still there while it\'s behind');
    await behind.bringToFront();
    await waitBlocked(behind);
    void front;
  });
  await it('back into a site left in history before the session', async () => {
    app.endSession();
    await until('rules off', async () => (await tb.rules()).length === 0);
    const page = await tb.tab('https://x.com/history');
    await page.goto('https://ok.test/next');
    app.startSession(SITES);
    await sleep(200);
    await page.goBack().catch(() => {});
    await waitBlocked(page);
  });
  await it('back into a page kept in the browser\'s cache before the session', async () => {
    app.endSession();
    await until('rules off', async () => (await tb.rules()).length === 0);
    const page = await tb.tab('https://x.com/cacheable');
    await page.goto('https://ok.test/next');
    app.startSession(SITES);
    await sleep(200);
    await page.goBack().catch(() => {});
    await waitBlocked(page);
  });
  await it('history.pushState into a blocked part (how YouTube moves to Shorts)', async () => {
    const page = await tb.tab('https://youtube.com/');
    await page.evaluate(() => history.pushState({}, '', '/shorts/abc'));
    await waitBlocked(page);
    const hash = await page.evaluate(() => location.hash);
    assert(hash.includes('/shorts/abc'), `the address: ${hash}`);
  });
  await it('back from a part blocked inside the page gets out of it', async () => {
    const page = await tb.tab('https://youtube.com/');
    await page.evaluate(() => history.pushState({}, '', '/shorts/abc'));
    await waitBlocked(page);
    await sleep(300);
    await page.goBack().catch(() => {});
    await waitAt(page, 'https://youtube.com/');
  });
  await it('history.replaceState into a blocked part', async () => {
    const page = await tb.tab('https://youtube.com/');
    await page.evaluate(() => history.replaceState({}, '', '/shorts/xyz'));
    await waitBlocked(page);
  });
  await it('a hash change doesn\'t count as leaving: youtube.com stays', async () => {
    const page = await tb.tab('https://youtube.com/watch');
    await page.evaluate(() => { location.hash = 'shorts'; });
    await sleep(300);
    assert(!isBlock(page), 'blocked on a hash');
  });
  await it('an iframe of the site: only whole pages are stopped', async () => {
    const since = Date.now();
    const page = await tb.tab('https://ok.test/');
    await page.evaluate(() => { const f = document.createElement('iframe'); f.src = 'https://x.com/embedded'; document.body.append(f); });
    await sleep(400);
    assert(!isBlock(page), 'the page itself');
    assert(web.served('x.com', since), 'expected the frame to load, by design');
  });
  await it('a site with its own service worker is blocked', async () => {
    app.endSession();
    await until('rules off', async () => (await tb.rules()).length === 0);
    const first = await tb.tab('https://pwa.test/pwa');
    await first.waitForFunction(() => navigator.serviceWorker.controller, { timeout: 5000 });
    await first.close();
    app.startSession({ preset: 'standard', sites: ['pwa.test'] });
    await until('rule', async () => (await tb.rules()).some((r) => r.condition.regexFilter.includes('pwa')));
    const page = await tb.tab('https://pwa.test/pwa');
    await waitBlocked(page);
  });
  await it('a site with its own service worker never gets to run first', { bug: 'B-site-worker' }, async () => {
    const since = Date.now();
    const page = await tb.tab('https://pwa.test/pwa');
    await waitBlocked(page);
    await sleep(400);
    const ran = web.requests.filter((r) => r.at >= since && r.host === 'beacon.test');
    app.startSession(SITES);
    assertEqual(ran.map((r) => r.path).join(','), '', 'the page ran');
  });
  await it('a web page can\'t use the block page to count visits', { bug: 'B-war-visit' }, async () => {
    const before = app.messages('blockedVisit').length;
    const page = await tb.tab('https://ok.test/');
    await page.evaluate((src) => { const f = document.createElement('iframe'); f.src = src; document.body.append(f); }, `${BLOCK}?kind=site&target=evil.test#https://evil.test/`);
    await sleep(600);
    const counted = app.messages('blockedVisit').slice(before);
    assertEqual(counted.map((m) => m.host).join(','), '', 'visits counted from a web page');
  });
  await it('a second stopped visit to the same address in one tab counts', { bug: 'B-visit-count' }, async () => {
    const before = app.messages('blockedVisit').length;
    const page = await tb.tab('https://x.com/twice');
    await waitBlocked(page);
    await page.goto('https://ok.test/between');
    await page.goto('https://x.com/twice').catch(() => {});
    await waitBlocked(page);
    await sleep(300);
    assertEqual(app.messages('blockedVisit').length - before, 2, 'visits counted');
  });
  await it('the session pausing or going on a break lifts the block', async () => {
    app.pauseSession();
    await until('rules off', async () => (await tb.rules()).length === 0);
    const page = await tb.tab('https://x.com/while-paused');
    assertEqual(page.url(), 'https://x.com/while-paused', 'paused');
    app.startSession(SITES);
    await waitBlocked(page);
    app.startBreak();
    await until('rules off', async () => (await tb.rules()).length === 0);
    const again = await tb.tab('https://x.com/on-break');
    assertEqual(again.url(), 'https://x.com/on-break', 'on a break');
    app.startSession(SITES);
    await waitBlocked(again);
  });
  await it('the session ending: the block page offers the site, and it opens', async () => {
    const page = await tb.tab('https://x.com/ended');
    await waitBlocked(page);
    app.endSession();
    const title = await message(page, 'overTitle');
    await until('the session-over view', async () => (await pageText(page)).includes(title));
    const open = await buttonFor(page, 'overOpenHost', 'x.com');
    await press(page, 'overOpenHost', 'x.com');
    await waitAt(page, 'https://x.com/ended');
    app.startSession(SITES);
  });
  await it('rapid changes of the list settle on the last one', async () => {
    const lists = [['a.test'], ['a.test', 'b.test', 'c.test'], ['a.test'], ['a.test', 'b.test', 'c.test', 'd.test', 'e.test'], ['x.com'], ['a.test', 'b.test', 'c.test', 'd.test', 'e.test', 'f.test', 'x.com']];
    for (let round = 0; round < 5; round += 1) {
      for (const sites of lists) app.set({ sites });
      await sleep(400);
      const rules = await tb.rules();
      assertEqual(rules.length, lists.at(-1).length + 1, `rules in round ${round}`);
    }
    app.set({ sites: ['x.com'] });
  });
  await it('a site in Unicode: the rest of the list holds', async () => {
    app.set({ sites: ['x.com', 'münchen.test'] });
    await sleep(400);
    const page = await tb.tab('https://x.com/still');
    await waitBlocked(page, 1500);
  });
  await it('a site in Unicode is blocked too', { bug: 'B-unicode-site' }, async () => {
    const other = await tb.tab('https://münchen.test/');
    app.set({ sites: ['x.com'] });
    await waitBlocked(other, 1500);
  });
});

// ---------------------------------------------------------------------------
// 4. Presets: the waits and what each one offers

group('presets on the block page', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();

  await it('Standard: "Let me through" is locked for 5 s, and Return does nothing', async () => {
    app.startSession({ preset: 'standard', sites: ['x.com'] });
    const page = await tb.tab('https://x.com/std');
    await waitBlocked(page);
    await page.waitForSelector('.actions button');
    const opened = Date.now();
    const pass = await buttonFor(page, 'blockLetMeThrough');
    assert(await pass.evaluate((b) => b.disabled), 'locked at first');
    await page.keyboard.press('Enter');
    await sleep(2000);
    assertEqual(app.messages('requestPass').length, 0, 'passes asked for during the wait');
    assert(await pass.evaluate((b) => b.disabled), 'locked at 2 s');
    await page.reload();
    await page.waitForSelector('.actions button');
    const reloaded = Date.now();
    const again = await buttonFor(page, 'blockLetMeThrough');
    await sleep(3500);
    assert(await again.evaluate((b) => b.disabled), `a reload restarts the wait (${Date.now() - opened} ms since the first load)`);
    await until('the button to unlock', () => again.evaluate((b) => !b.disabled), 3000);
    const waited = Date.now() - reloaded;
    assert(waited >= 4800, `unlocked after ${waited} ms`);
    assert((await again.evaluate((b) => b.textContent)).trim().length > 0, 'its label');
  });

  await it('Standard: a state pushed after the wait keeps the button\'s words', async () => {
    app.startSession({ preset: 'standard', sites: ['x.com'] });
    const page = await tb.tab('https://x.com/std2');
    await waitBlocked(page);
    await sleep(5400);
    app.session.segments = [['f', 120]];
    app.push(true);
    await sleep(400);
    const buttons = await buttonTexts(page);
    await shot(page, 'block-standard-after-state');
    const empty = buttons.filter((b) => !b.text);
    assertEqual(empty.length, 0, `empty buttons in ${JSON.stringify(buttons)}`);
  });

  await it('Standard: Return after the wait takes a 2-minute pass', async () => {
    app.startSession({ preset: 'standard', sites: ['x.com'] });
    const page = await tb.tab('https://x.com/enter');
    await waitBlocked(page);
    await sleep(5300);
    await page.keyboard.press('Enter');
    const asked = await until('requestPass', () => app.messages('requestPass').at(-1));
    assertEqual(asked.host, 'x.com', 'host');
    await waitAt(page, 'https://x.com/enter');
    const pass = app.makeState().blocking.passes[0];
    assert(pass.until - Date.now() > 115000 && pass.until - Date.now() <= 120000, `pass of ${pass.until - Date.now()} ms`);
    app.endSession();
  });

  await it('Gentle: "Let me through" works right away, by click and by Return', async () => {
    app.received.length = 0;
    app.startSession({ preset: 'gentle', sites: ['x.com'] });
    const page = await tb.tab('https://x.com/gentle');
    await waitBlocked(page);
    await page.waitForSelector('.actions button');
    const pass = await buttonFor(page, 'blockLetMeThrough');
    assert(!(await pass.evaluate((b) => b.disabled)), 'open at once');
    await press(page, 'blockLetMeThrough');
    await waitAt(page, 'https://x.com/gentle');
    app.startSession({ preset: 'gentle', sites: ['x.com'] });
    await waitBlocked(page);
    await page.waitForSelector('.actions button');
    await page.keyboard.press('Enter');
    await waitAt(page, 'https://x.com/gentle');
    app.endSession();
  });

  await it('Strict: no pass; "It\'s for work" is locked for 10 s, then works', async () => {
    app.received.length = 0;
    app.startSession({ preset: 'strict', sites: ['x.com'], backTo: 'Xcode' });
    const page = await tb.tab('https://x.com/strict?a=1');
    await waitBlocked(page);
    await page.waitForSelector('.actions button');
    await shot(page, 'block-strict');
    const opened = Date.now();
    assertEqual(await buttonFor(page, 'blockLetMeThrough'), null, 'a pass button');
    const work = await buttonFor(page, 'blockForWork');
    assert(await work.evaluate((b) => b.disabled), 'locked at first');
    await page.keyboard.press('Enter');
    await sleep(8000);
    assert(await work.evaluate((b) => b.disabled), 'locked at 8 s');
    assertEqual(app.messages('allowForWork').length, 0, 'asked for during the wait');
    await until('for-work to unlock', () => work.evaluate((b) => !b.disabled), 4000);
    assert(Date.now() - opened >= 9800, `unlocked after ${Date.now() - opened} ms`);
    await press(page, 'blockForWork');
    await waitAt(page, 'https://x.com/strict?a=1');
    assertEqual(app.messages('allowForWork').at(-1).host, 'x.com', 'host');
    await sleep(300);
    await page.reload();
    await sleep(200);
    assertEqual(page.url(), 'https://x.com/strict?a=1', 'for work lasts the session');
    app.endSession();
  });

  await it('Strict: for-work\'s words survive a state pushed after the wait', async () => {
    app.startSession({ preset: 'strict', sites: ['x.com'] });
    const page = await tb.tab('https://x.com/strict2');
    await waitBlocked(page);
    await sleep(10500);
    app.session.segments = [['f', 120]];
    app.push(true);
    await sleep(400);
    const buttons = await buttonTexts(page);
    assertEqual(buttons.filter((b) => !b.text).length, 0, `empty buttons in ${JSON.stringify(buttons)}`);
    const close = await message(page, 'closeTab');
    assertEqual(buttons.filter((b) => b.text === close).length, 1, `"Close tab" buttons with no app to go back to in ${JSON.stringify(buttons)}`);
    app.endSession();
  });

  await it('Strict: a part of a site has no pass either', async () => {
    app.startSession({ preset: 'strict', sites: [], parts: ['youtube.com/shorts'] });
    const page = await tb.tab('https://youtube.com/shorts/a');
    await waitBlocked(page);
    await page.waitForSelector('.actions button');
    assertEqual(await buttonFor(page, 'blockLetMeThrough'), null, 'a pass button');
    await shot(page, 'block-strict-part');
    app.endSession();
  });

  await it('Strict: refused by the app even if the page asks for a pass', async () => {
    app.startSession({ preset: 'strict', sites: ['x.com'] });
    const page = await tb.tab('https://x.com/');
    await waitBlocked(page);
    const reply = await page.evaluate(() => chrome.runtime.sendMessage({ type: 'passThrough', url: 'https://x.com/' }));
    assertEqual(reply.ok, false, 'reply');
    assertEqual(reply.error, 'strict', 'error');
    assert(isBlock(page), 'still blocked');
    app.endSession();
  });

  await it('the waits hold in the app too: a pass asked for at once in Standard is refused', { bug: 'B-wait-client-only' }, async () => {
    // Not reachable by clicking, only by script in the extension's own page. The
    // app's grantPass has no idea when the page opened, so this is by design today.
    app.startSession({ preset: 'standard', sites: ['x.com'] });
    const page = await tb.tab('https://x.com/');
    await waitBlocked(page);
    const reply = await page.evaluate(() => chrome.runtime.sendMessage({ type: 'passThrough', url: 'https://x.com/' }));
    app.endSession();
    assertEqual(reply.ok, false, 'reply');
  });

  await it('Back to work and Esc: with a focus app it stays, without one the tab closes', async () => {
    app.startSession({ preset: 'standard', sites: ['x.com'], backTo: 'Xcode' });
    const page = await tb.tab('https://x.com/');
    await waitBlocked(page);
    await page.waitForSelector('.actions button');
    await page.keyboard.press('Escape');
    await until('backToWork', () => app.messages('backToWork').length > 0);
    await sleep(300);
    assert(!page.isClosed(), 'the tab stays when an app comes forward');
    app.endSession();
    app.startSession({ preset: 'standard', sites: ['x.com'], backTo: null });
    const two = await tb.tab('https://x.com/');
    await waitBlocked(two);
    await two.waitForSelector('.actions button');
    await two.keyboard.press('Escape').catch(() => {});
    await until('the tab to close', () => two.isClosed());
    app.endSession();
  });
});

// ---------------------------------------------------------------------------
// 5. The pass countdown (#86), never run in a browser before

group('pass countdown', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  const sites = ['x.com', 'other.test'];

  // A pass on a page: the block page, its button, and the tab let through.
  const takePass = async (page) => {
    await waitBlocked(page);
    await page.waitForSelector('.actions button');
    await press(page, 'blockLetMeThrough');
  };

  await it('an instant page gets the countdown', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/instant');
    await takePass(page);
    await waitAt(page, 'https://x.com/instant');
    await until('the pill', () => hasPill(page), 3000);
    const text = await pillText(page);
    assert(/x\.com/.test(text) && /\d:\d\d/.test(text), `the pill says: ${text}`);
    await shot(page, 'pass-pill');
    await sleep(1200);
    const later = await pillText(page);
    assert(later !== text, `it counts down: ${later}`);
    // The app needs to hear about the page to count it as drift.
    await until('the report of the site', () => reportsOf(app, 'https://x.com/instant').length > 0, 3000);
  });

  await it('ten instant pages in a row: never missed', async () => {
    app.startSession({ preset: 'gentle', sites });
    for (let i = 0; i < 10; i += 1) {
      app.passes.clear();
      app.push(true);
      await sleep(100);
      const page = await tb.tab(`https://x.com/row${i}`);
      await takePass(page);
      await waitAt(page, `https://x.com/row${i}`);
      await until(`the pill on try ${i}`, () => hasPill(page), 3000);
      await page.close();
    }
  });

  await it('a page taking 3 s to load gets it once it\'s loaded', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/slow?ms=3000');
    await takePass(page);
    await waitAt(page, 'https://x.com/slow?ms=3000');
    assert(!(await hasPill(page)), 'not during the load');
    await until('the pill', () => hasPill(page), 6000);
  });

  await it('a redirect on the same site', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/redirect?to=https://x.com/landed');
    await takePass(page);
    await waitAt(page, 'https://x.com/landed');
    await until('the pill', () => hasPill(page), 3000);
  });

  await it('a redirect to a subdomain of the site', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/redirect?to=https://m.x.com/landed');
    await takePass(page);
    await waitAt(page, 'https://m.x.com/landed');
    await until('the pill', () => hasPill(page), 3000);
  });

  await it('a redirect from the site to another blocked one stays blocked', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/redirect?to=https://other.test/landed');
    await takePass(page);
    await waitBlocked(page);
    await until('its address on the block page', () => page.url().includes('other.test'), 3000);
  });

  await it('a redirect from the site to somewhere allowed: no countdown there', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/redirect?to=https://work.test/landed');
    await takePass(page);
    await waitAt(page, 'https://work.test/landed');
    await sleep(600);
    assert(!(await hasPill(page)), `a countdown on work.test: ${await pillText(page)}`);
  });

  await it('a tab that closes during the load: nothing goes wrong, and the next pass works', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/slow?ms=3000');
    await takePass(page);
    await sleep(300);
    await page.close();
    await sleep(3200);
    const next = await tb.tab('https://other.test/next');
    await takePass(next);
    await waitAt(next, 'https://other.test/next');
    await until('the pill', () => hasPill(next), 3000);
  });

  await it('a tab left for an allowed site during the load: no countdown there', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/slow?ms=4000');
    await takePass(page);
    await sleep(400);
    await page.goto('https://work.test/left').catch(() => {});
    await sleep(600);
    assert(!(await hasPill(page)), `a countdown on work.test: ${await pillText(page)}`);
  });

  await it('the pass ending on an open page: the block comes back, and the address with it', async () => {
    app.startSession({ preset: 'gentle', sites });
    app.passMs = 4000;
    const page = await tb.tab('https://x.com/ends?x=1');
    await takePass(page);
    await waitAt(page, 'https://x.com/ends?x=1');
    await until('the pill', () => hasPill(page), 3000);
    await waitBlocked(page, 7000);
    assert((await page.evaluate(() => location.hash)).includes('/ends?x=1'), 'its address');
    assertEqual((await tb.rules()).length, 2, 'rules back on');
    const again = await tb.tab('https://x.com/after');
    await waitBlocked(again);
    app.passMs = 120000;
  });

  await it('the pill goes with the pass', async () => {
    app.startSession({ preset: 'gentle', sites });
    app.passMs = 3000;
    const page = await tb.tab('https://x.com/pill');
    await takePass(page);
    await until('the pill', () => hasPill(page), 3000);
    // The page may turn into the block page at the same moment; either way, no pill.
    await until('the pill to go', async () => !(await hasPill(page)), 6000);
    app.passMs = 120000;
  });

  await it('another tab on the host: goes through during the pass, blocks with it', async () => {
    app.startSession({ preset: 'gentle', sites });
    app.passMs = 5000;
    const page = await tb.tab('https://x.com/one');
    await takePass(page);
    await waitAt(page, 'https://x.com/one');
    const two = await tb.tab('https://x.com/two');
    assertEqual(two.url(), 'https://x.com/two', 'the second tab during the pass');
    await waitBlocked(two, 8000);
    // The first is behind by now: it blocks when it comes to the front.
    assert(!isBlock(page), 'not while it\'s behind');
    await page.bringToFront();
    await waitBlocked(page);
    app.passMs = 120000;
  });

  await it('another tab on the host shows the countdown too', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/one');
    await takePass(page);
    await waitAt(page, 'https://x.com/one');
    const two = await tb.tab('https://x.com/two');
    await until('the pill on the second tab', () => hasPill(two), 3000);
  });

  await it('a reload during the pass keeps the countdown', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/reload');
    await takePass(page);
    await until('the pill', () => hasPill(page), 3000);
    await page.reload();
    await until('the pill after the reload', () => hasPill(page), 3000);
  });

  await it('moving on the site during the pass keeps the countdown', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/first');
    await takePass(page);
    await until('the pill', () => hasPill(page), 3000);
    await page.goto('https://x.com/second');
    await until('the pill on the next page', () => hasPill(page), 3000);
  });

  await it('a tab that left during the pass: the site blocks when it goes back after it', async () => {
    app.startSession({ preset: 'gentle', sites });
    app.passMs = 3000;
    const page = await tb.tab('https://x.com/left');
    await takePass(page);
    await waitAt(page, 'https://x.com/left');
    await page.goto('https://work.test/elsewhere');
    await sleep(3500);
    assert(!isBlock(page), 'work.test is fine');
    await page.goBack().catch(() => {});
    await waitBlocked(page);
    app.passMs = 120000;
  });

  await it('the pill\'s button closes the tab when there\'s no app to go back to', async () => {
    app.startSession({ preset: 'gentle', sites, backTo: null });
    const page = await tb.tab('https://x.com/button');
    await takePass(page);
    await until('the pill', () => hasPill(page), 3000);
    await sleep(100);
    const box = await page.evaluate(() => { const r = document.getElementById('focusguard-pass').getBoundingClientRect(); return { x: r.right - 40, y: r.top + r.height / 2 }; });
    await page.mouse.click(box.x, box.y);
    await until('the tab to close', () => page.isClosed(), 4000);
  });

  await it('the toolbar badge counts the pass down on its tab, and stops after', async () => {
    app.startSession({ preset: 'gentle', sites });
    app.passMs = 4000;
    const page = await tb.tab('https://x.com/badge');
    await takePass(page);
    await waitAt(page, 'https://x.com/badge');
    const worker = await tb.worker();
    const badge = await until('the badge', async () => { const b = await worker.evaluate(() => chrome.action.getBadgeText({})); return /\d:\d\d/.test(b) && b; }, 3000);
    assert(/^\d:\d\d$/.test(badge), `badge ${badge}`);
    await waitBlocked(page, 7000);
    await until('the badge to clear', async () => (await worker.evaluate(() => chrome.action.getBadgeText({}))) === '', 3000);
    app.passMs = 120000;
  });

  await it('an app that has hung: a new tab is still stopped when the pass ends', async () => {
    app.startSession({ preset: 'gentle', sites });
    app.passMs = 2000;
    const page = await tb.tab('https://x.com/hung');
    await takePass(page);
    await waitAt(page, 'https://x.com/hung');
    await sleep(100);
    app.silent = true;
    try {
      await sleep(2500);
      const fresh = await tb.tab('https://x.com/fresh');
      await sleep(300);
      assert(isBlock(fresh), 'the site loads after the pass');
    } finally {
      app.silent = false;
      app.passMs = 120000;
      app.lastSent = null;
      app.push(true);
    }
  });

  await it('a part: the pass lets the path through, then it blocks again', async () => {
    app.startSession({ preset: 'gentle', sites: [], parts: ['youtube.com/shorts'] });
    app.passMs = 3000;
    const page = await tb.tab('https://www.youtube.com/shorts/abc');
    await takePass(page);
    await waitAt(page, 'https://www.youtube.com/shorts/abc');
    await until('the pill', () => hasPill(page), 3000);
    await waitBlocked(page, 6000);
    app.passMs = 120000;
  });

  await it('a pass taken on a subdomain doesn\'t open the whole site', async () => {
    app.startSession({ preset: 'gentle', sites: ['x.com'] });
    const page = await tb.tab('https://m.x.com/sub');
    await takePass(page);
    await waitAt(page, 'https://m.x.com/sub');
    await sleep(100);
    const since = Date.now();
    for (const url of ['https://x.com/main', 'https://www.x.com/main', 'https://other.x.com/main']) {
      const other = await tb.tab(url);
      await sleep(300);
      assert(isBlock(other), `${url} opened on a pass taken on m.x.com`);
    }
    assert(!web.served('x.com', since) && !web.served('www.x.com', since), 'the site was asked: the rule let it through first');
    await page.reload();
    await sleep(300);
    assertEqual(page.url(), 'https://m.x.com/sub', 'm.x.com itself, during its pass');
  });

  await it('a pass taken on the site covers www. and its subdomains', async () => {
    app.startSession({ preset: 'gentle', sites: ['x.com'] });
    const page = await tb.tab('https://x.com/whole');
    await takePass(page);
    await waitAt(page, 'https://x.com/whole');
    await sleep(100);
    for (const url of ['https://www.x.com/w', 'https://m.x.com/w']) {
      const other = await tb.tab(url);
      await sleep(300);
      assertEqual(other.url(), url, 'during the pass');
    }
  });

  await it('a pass taken on www. covers the site', async () => {
    app.startSession({ preset: 'gentle', sites: ['x.com'] });
    const page = await tb.tab('https://www.x.com/w');
    await takePass(page);
    await waitAt(page, 'https://www.x.com/w');
    await sleep(100);
    const other = await tb.tab('https://x.com/bare');
    await sleep(300);
    assertEqual(other.url(), 'https://x.com/bare', 'during the pass');
  });

  await it('"for work" follows the same rule: a subdomain doesn\'t open the site, the site covers www.', async () => {
    app.startSession({ preset: 'gentle', sites: ['x.com'] });
    const sub = await tb.tab('https://m.x.com/work');
    await waitBlocked(sub);
    await press(sub, 'blockForWork');
    await waitAt(sub, 'https://m.x.com/work');
    await sleep(100);
    const site = await tb.tab('https://x.com/work');
    await waitBlocked(site);
    await press(site, 'blockForWork');
    await waitAt(site, 'https://x.com/work');
    await sleep(100);
    const www = await tb.tab('https://www.x.com/work');
    await sleep(300);
    assertEqual(www.url(), 'https://www.x.com/work', 'www. once the site is for work');
    app.endSession();
  });

  await it('a pass on a subdomain doesn\'t get past a limit on the site', async () => {
    app.set({ limits: [REDDIT_LIMIT()] });
    app.startSession({ preset: 'gentle', sites: ['reddit.com'] });
    app.passes.set('old.reddit.com', Date.now() + 60000);
    app.push(true);
    await sleep(300);
    const page = await tb.tab('https://old.reddit.com/');
    await waitBlocked(page);
    assert(page.url().includes('kind=limit'), page.url());
    app.set({ limits: [] });
    app.endSession();
  });

  await it('the end of the session clears a pass', async () => {
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/session');
    await takePass(page);
    await waitAt(page, 'https://x.com/session');
    app.startSession({ preset: 'gentle', sites });
    await waitBlocked(page);
    app.endSession();
  });
});

// ---------------------------------------------------------------------------
// 6. Daily limits

group('daily limits', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  const reach = (over) => { app.set({ limits: [REDDIT_LIMIT(over)] }); };

  await it('blocks outside a session, in one, on a break and paused', async () => {
    reach();
    await until('rule', async () => (await tb.rules()).length === 1);
    const ready = await tb.tab('https://reddit.com/r/all');
    await waitBlocked(ready);
    await ready.waitForSelector('.limit-card');
    await shot(ready, 'block-limit-standard');
    app.startSession({ preset: 'standard', sites: [] });
    const session = await tb.tab('https://www.reddit.com/');
    await waitBlocked(session);
    app.pauseSession();
    await sleep(200);
    const paused = await tb.tab('https://old.reddit.com/');
    await waitBlocked(paused);
    app.startBreak();
    await sleep(200);
    const onBreak = await tb.tab('https://reddit.com/x');
    await waitBlocked(onBreak);
    app.set({ phase: 'ready', session: null });
    assert(onBreak.url().includes('kind=limit'), `its kind: ${onBreak.url()}`);
  });

  await it('Free: the extension leaves limits to the app', async () => {
    app.set({ plan: FREE });
    reach();
    await until('no rules', async () => (await tb.rules()).length === 0);
    const page = await tb.tab('https://reddit.com/free');
    assertEqual(page.url(), 'https://reddit.com/free', 'on the free plan');
    app.set({ plan: PRO });
    await until('its rule to land', async () => (await tb.rules()).length === 1);
  });

  await it('a limit lifted right after it was reached leaves no rule behind', async () => {
    // Two rule updates at once used to leave the first's rule behind.
    for (let round = 0; round < 10; round += 1) {
      reach({ reached: false, usedSeconds: 0 });
      await sleep(150);
      reach();
      reach({ reached: false, usedSeconds: 0 });
      await sleep(250);
      assertEqual((await tb.rules()).length, 0, `rules left in round ${round}`);
    }
    reach();
    await until('its rule to land', async () => (await tb.rules()).length === 1);
  });

  await it('a limit reached while on the site takes the tab straight away', async () => {
    reach({ reached: false, usedSeconds: 1700 });
    await until('no rule', async () => (await tb.rules()).length === 0);
    const page = await tb.tab('https://reddit.com/reading');
    assertEqual(page.url(), 'https://reddit.com/reading', 'under the limit');
    reach();
    await waitBlocked(page);
    assert(page.url().includes('kind=limit'), page.url());
  });

  await it('a pass doesn\'t get past a limit', async () => {
    reach();
    app.startSession({ preset: 'gentle', sites: ['reddit.com'] });
    app.passes.set('reddit.com', Date.now() + 60000);
    app.push(true);
    await sleep(300);
    const page = await tb.tab('https://reddit.com/passed');
    await waitBlocked(page);
    app.endSession();
  });

  await it('Standard: +5 min after a 5 s wait, once a day', async () => {
    app.set({ preset: 'standard' });
    reach();
    const page = await tb.tab('https://reddit.com/r/a?x=1');
    await waitBlocked(page);
    await page.waitForSelector('.limit-card');
    const opened = Date.now();
    const extra = await buttonFor(page, 'limitMoreMinutes', 5);
    assert(extra, 'the +5 button');
    assert(await extra.evaluate((b) => b.disabled), 'locked at first');
    await page.keyboard.press('Enter');
    await sleep(2000);
    assertEqual(app.messages('requestExtraTime').length, 0, 'asked for during the wait');
    await until('it to unlock', () => extra.evaluate((b) => !b.disabled), 4000);
    assert(Date.now() - opened >= 4800, `unlocked after ${Date.now() - opened} ms`);
    await press(page, 'limitMoreMinutes', 5);
    await waitAt(page, 'https://reddit.com/r/a?x=1');
    assertEqual(app.limits[0].minutes, 35, 'minutes');
    assertEqual(app.limits[0].extraLeft, 0, 'grants left');
    // Used up again: no more on offer.
    reach({ minutes: 35, usedSeconds: 2100, extraLeft: 0 });
    await waitBlocked(page);
    await page.waitForSelector('.limit-card');
    assertEqual(await buttonFor(page, 'limitMoreMinutes', 5), null, 'a second +5');
    await shot(page, 'block-limit-used');
  });

  await it('Standard: the +5 button keeps its words if a state arrives after the wait', async () => {
    app.set({ preset: 'standard' });
    reach();
    const page = await tb.tab('https://reddit.com/words');
    await waitBlocked(page);
    await page.waitForSelector('.limit-card');
    await sleep(5400);
    reach({ visits: 7 });
    await sleep(300);
    const buttons = await buttonTexts(page);
    assertEqual(buttons.filter((b) => !b.text).length, 0, `empty buttons in ${JSON.stringify(buttons)}`);
  });

  await it('Gentle: +5 min at once, three times', async () => {
    app.set({ preset: 'gentle' });
    reach({ extraLeft: 3 });
    const page = await tb.tab('https://reddit.com/gentle');
    for (let left = 3; left > 0; left -= 1) {
      await waitBlocked(page);
      await page.waitForSelector('.limit-card');
      const extra = await buttonFor(page, 'limitMoreMinutes', 5);
      assert(!(await extra.evaluate((b) => b.disabled)), `open at once with ${left} left`);
      await press(page, 'limitMoreMinutes', 5);
      await waitAt(page, 'https://reddit.com/gentle');
      assertEqual(app.limits[0].extraLeft, left - 1, 'grants left');
      const limit = app.limits[0];
      app.set({ limits: [{ ...limit, usedSeconds: limit.minutes * 60, reached: true }] });
    }
    await waitBlocked(page);
    await page.waitForSelector('.limit-card');
    assertEqual(await buttonFor(page, 'limitMoreMinutes', 5), null, 'a fourth +5');
  });

  await it('Strict: no extra time', async () => {
    app.set({ preset: 'strict' });
    reach({ extraLeft: 0 });
    const page = await tb.tab('https://reddit.com/strict');
    await waitBlocked(page);
    await page.waitForSelector('.limit-card');
    assertEqual(await buttonFor(page, 'limitMoreMinutes', 5), null, 'a +5 button');
    await shot(page, 'block-limit-strict');
    const reply = await page.evaluate(() => chrome.runtime.sendMessage({ type: 'extraTime', site: 'reddit.com', url: 'https://reddit.com/' }));
    assertEqual(reply.ok, false, 'the app refuses it');
    assert(isBlock(page), 'still blocked');
  });

  await it('midnight: the limit resets, new tabs load', async () => {
    app.set({ preset: 'standard' });
    reach();
    await until('rule', async () => (await tb.rules()).length === 1);
    const before = await tb.tab('https://reddit.com/');
    await waitBlocked(before);
    reach({ usedSeconds: 0, reached: false, extraLeft: 1, visits: 0 });
    await until('no rule', async () => (await tb.rules()).length === 0);
    const after = await tb.tab('https://reddit.com/morning');
    assertEqual(after.url(), 'https://reddit.com/morning', 'after 00:00');
  });

  await it('midnight: a limit page left open says the site is open, and opens it', async () => {
    reach();
    const page = await tb.tab('https://reddit.com/overnight?a=1');
    await waitBlocked(page);
    await page.waitForSelector('.limit-card');
    const before = app.messages('requestExtraTime').length;
    reach({ usedSeconds: 0, reached: false, extraLeft: 1, visits: 0 });
    const open = await message(page, 'overLede', 'reddit.com');
    await until('the site-is-open view', async () => (await pageText(page)).includes(open));
    await shot(page, 'block-limit-after-midnight');
    assertEqual(await buttonFor(page, 'limitMoreMinutes', 5), null, 'a +5 button on a limit that has reset');
    await press(page, 'overOpenHost', 'reddit.com');
    await waitAt(page, 'https://reddit.com/overnight?a=1');
    assertEqual(app.messages('requestExtraTime').length, before, 'extra time taken');
  });

  await it('the app quitting doesn\'t leave a limit page with no way to the site', async () => {
    reach();
    const page = await tb.tab('https://reddit.com/stuck');
    await waitBlocked(page);
    await page.waitForSelector('.limit-card');
    await app.stop();
    try {
      await until('rules off', async () => (await tb.rules()).length === 0);
      const title = await message(page, 'overOpenHost', 'reddit.com');
      await sleep(600);
      await shot(page, 'block-limit-app-closed');
      assert((await pageText(page)).includes(title), `no button to reddit.com: ${(await buttonTexts(page)).map((b) => b.text).join(', ')}`);
      await press(page, 'overOpenHost', 'reddit.com');
      await waitAt(page, 'https://reddit.com/stuck');
    } finally {
      await app.start();
      await tb.connected();
    }
  });
});

// ---------------------------------------------------------------------------
// 7. Free: pausing a tab

group('free: pause the tab', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  app.set({ plan: FREE });
  app.startSession({ preset: 'standard', sites: ['x.com'] });
  const fields = (id, state, url = 'https://x.com/home?a=1') => `id=${id}&host=x.com&url=${encodeURIComponent(url)}&state=${state}&ends=${Math.round(Date.now() / 1000) + 1800}&back=Xcode`;

  await it('Free doesn\'t block before load, even with site access', async () => {
    assertEqual((await tb.rules()).length, 0, 'rules');
    const page = await tb.tab('https://x.com/free');
    assertEqual(page.url(), 'https://x.com/free', 'x.com');
  });

  await it('pauses the front tab, moves through its states and gives the address back', async () => {
    const page = await tb.tab('https://x.com/home?a=1');
    const report = await until('the report', () => reportsOf(app, 'https://x.com/home?a=1').at(-1));
    app.sendAll({ type: 'pauseTab', rid: 'r1', host: 'x.com', tabId: report.tab.tabId, fragment: fields('p1', 'paused') });
    const result = await until('pauseResult', () => app.messages('pauseResult').find((m) => m.rid === 'r1'));
    assert(result.ok, 'the tab paused');
    await until('the paused page', () => page.url().includes('kind=paused'));
    await page.waitForSelector('.actions button');
    await shot(page, 'paused-free');
    assertEqual((await badWords(page)).join(' / '), '', 'raw text');
    const later = await buttonFor(page, 'pausedReopenAfter');
    await press(page, 'pausedReopenAfter');
    await until('tabAction', () => app.messages('tabAction').find((m) => m.action === 'reopenLater' && m.pauseId === 'p1'));
    app.sendAll({ type: 'redirectTab', pauseId: 'p1', fragment: fields('p1', 'queued') });
    const queued = await message(page, 'pausedQueuedTitle', 'x.com');
    await until('queued', async () => (await pageText(page)).includes(queued));
    app.sendAll({ type: 'redirectTab', pauseId: 'p1', fragment: fields('p1', 'over') });
    const over = await message(page, 'pausedOverTitle');
    await until('over', async () => (await pageText(page)).includes(over));
    app.sendAll({ type: 'redirectTab', pauseId: 'p1', url: 'https://x.com/home?a=1' });
    await waitAt(page, 'https://x.com/home?a=1');
  });

  await it('"Reopen" on the paused page gives the tab back, without the app', async () => {
    const page = await tb.tab('https://x.com/reopen');
    const report = await until('the report', () => reportsOf(app, 'https://x.com/reopen').at(-1));
    app.sendAll({ type: 'pauseTab', rid: 'r2', host: 'x.com', tabId: report.tab.tabId, fragment: fields('p2', 'over', 'https://x.com/reopen') });
    await until('the paused page', () => page.url().includes('kind=paused'));
    await page.waitForSelector('.actions button');
    const reopen = await buttonFor(page, 'pausedReopenHost', 'x.com');
    await press(page, 'pausedReopenHost', 'x.com');
    await waitAt(page, 'https://x.com/reopen');
  });

  await it('no tab showing the host: answers false and touches nothing', async () => {
    const page = await tb.tab('https://work.test/');
    app.sendAll({ type: 'pauseTab', rid: 'r3', host: 'x.com', tabId: 999999, fragment: fields('p3', 'paused') });
    const result = await until('pauseResult', () => app.messages('pauseResult').find((m) => m.rid === 'r3'));
    assertEqual(result.ok, false, 'ok');
    assertEqual(page.url(), 'https://work.test/', 'the tab in front');
  });

  await it('a script address in the app\'s fields never opens', async () => {
    const page = await tb.tab('https://x.com/safe');
    const report = await until('the report', () => reportsOf(app, 'https://x.com/safe').at(-1));
    app.sendAll({ type: 'pauseTab', rid: 'r4', host: 'x.com', tabId: report.tab.tabId, fragment: fields('p4', 'over', 'javascript:alert(1)') });
    await until('the paused page', () => page.url().includes('kind=paused'));
    await page.waitForSelector('.actions button');
    assertEqual(await buttonFor(page, 'pausedReopenHost', 'x.com'), null, 'a reopen button for a script address');
    const entry = await page.evaluate(async () => (await chrome.storage.session.get('pausedTabs')).pausedTabs);
    const saved = Object.values(entry).find((e) => e.pauseId === 'p4');
    assertEqual(saved.url, 'https://x.com/safe', 'the saved address');
  });

  await it('a paused page after the session\'s end plus 2 min doesn\'t trap the tab', async () => {
    const stale = `id=p5&host=x.com&url=${encodeURIComponent('https://x.com/')}&state=paused&ends=${Math.round(Date.now() / 1000) - 300}`;
    const page = await tb.tab(`${BLOCK}?kind=paused#${stale}`);
    await page.waitForSelector('.actions button');
    const over = await message(page, 'pausedOverTitle');
    await until('over', async () => (await pageText(page)).includes(over));
  });
  app.endSession();
  app.set({ plan: PRO });
});

// ---------------------------------------------------------------------------
// 8. Tracking reports

group('tracking', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  const reportedLast = (url) => until(`the last report to be ${url} (it's ${lastReport(app)?.url})`, () => lastReport(app)?.url === url, 4000, 40);

  await it('the first page after connecting is reported, with its title', async () => {
    const page = await tb.tab('https://work.test/first');
    await reportedLast('https://work.test/first');
    assertEqual(lastReport(app).title, 'work.test/first', 'title');
    assert(Number.isInteger(lastReport(app).tabId) && Number.isInteger(lastReport(app).windowId), 'ids');
    void page;
  });

  await it('switching tabs reports the new one', async () => {
    const a = await tb.tab('https://work.test/a');
    const b = await tb.tab('https://work.test/b');
    await reportedLast('https://work.test/b');
    await a.bringToFront();
    await reportedLast('https://work.test/a');
    await b.bringToFront();
    await reportedLast('https://work.test/b');
  });

  await it('a title change on the page is reported', async () => {
    const page = await tb.tab('https://work.test/title');
    await reportedLast('https://work.test/title');
    await page.evaluate(() => { document.title = 'A new title'; });
    await until('the new title', () => lastReport(app)?.title === 'A new title', 3000);
  });

  await it('history.pushState is reported', async () => {
    const page = await tb.tab('https://work.test/spa');
    await reportedLast('https://work.test/spa');
    await page.evaluate(() => history.pushState({}, '', '/spa/next'));
    await reportedLast('https://work.test/spa/next');
  });

  await it('closing the tab in front reports the one that takes over', async () => {
    const under = await tb.tab('https://work.test/under');
    const top = await tb.tab('https://work.test/top');
    await reportedLast('https://work.test/top');
    await top.close();
    await reportedLast('https://work.test/under');
    void under;
  });

  await it('a background tab loading is not reported', async () => {
    const front = await tb.tab('https://work.test/front');
    await reportedLast('https://work.test/front');
    await tb.sw(() => chrome.tabs.create({ url: 'https://work.test/behind', active: false }));
    await sleep(800);
    assertEqual(reportsOf(app, 'https://work.test/behind').length, 0, 'reports of the tab behind');
    assertEqual(lastReport(app).url, 'https://work.test/front', 'the last report');
    void front;
  });

  await it('own pages and browser pages go without an address', async () => {
    const own = await tb.tab(`${ORIGIN}/pages/options.html`);
    await until('own page', () => lastReport(app)?.url === null && lastReport(app)?.tabId != null, 3000);
    await own.close();
    const browserPage = await tb.tab('chrome://version');
    await until('chrome page', () => lastReport(app)?.url === null, 3000);
    await browserPage.close();
  });

  await it('a second window taking focus is reported', async () => {
    await tb.tab('https://work.test/win1');
    await reportedLast('https://work.test/win1');
    const windowId = await tb.sw(async () => (await chrome.windows.create({ url: 'https://work.test/win2', focused: true })).id);
    await reportedLast('https://work.test/win2');
    await tb.sw((id) => chrome.windows.remove(id), windowId);
  });

  await it('asked to refresh, it reports even if nothing changed', async () => {
    await tb.tab('https://work.test/refresh');
    await reportedLast('https://work.test/refresh');
    await sleep(300);
    const before = app.messages('tab').length;
    app.sendAll({ type: 'refresh' });
    await until('a report', () => app.messages('tab').length > before, 2000);
  });

  await it('connecting with a page already in front reports it', async () => {
    await tb.tab('https://work.test/reconnect');
    await reportedLast('https://work.test/reconnect');
    await app.stop();
    await until('the rules to clear', async () => (await tb.rules()).length === 0);
    await sleep(300);
    const page = await tb.tab('https://work.test/while-closed');
    await sleep(300);
    const before = app.received.length;
    await app.start();
    await tb.connected();
    await until('the report', () => app.received.slice(before).find((m) => m.type === 'tab' && m.tab?.url === 'https://work.test/while-closed'), 6000);
    void page;
  });

  await it('YouTube video by video: Pro sends the video\'s title and channel', async () => {
    app.set({ plan: PRO });
    await tb.tab('https://www.youtube.com/watch?v=abc');
    const report = await until('the video', () => lastReport(app)?.video, 4000);
    assertEqual(report.title, 'The video title', 'title');
    assertEqual(report.channel, 'Some Channel', 'channel');
  });

  await it('YouTube video by video: Free sends no video', async () => {
    app.set({ plan: FREE });
    await tb.tab('https://www.youtube.com/watch?v=free');
    await reportedLast('https://www.youtube.com/watch?v=free');
    await sleep(300);
    assertEqual(lastReport(app).video, undefined, 'video');
    app.set({ plan: PRO });
  });

  await it('YouTube: moving to another video inside the page sends it again', async () => {
    const page = await tb.tab('https://www.youtube.com/watch?v=one');
    await until('the first video', () => lastReport(app)?.video?.title === 'The video title', 4000);
    await page.evaluate(() => {
      history.pushState({}, '', '/watch?v=two');
      document.querySelector('h1.ytd-watch-metadata yt-formatted-string').textContent = 'Second video';
      document.title = 'Second video - YouTube';
    });
    await until('the second video', () => lastReport(app)?.url.endsWith('v=two') && lastReport(app)?.video?.title === 'Second video', 4000);
  });

  await it('the worker stays alive with the helper connected: it doesn\'t sleep between reports', async () => {
    await tb.worker();
    await sleep(35000);
    assert(tb.browser.targets().some((t) => t.type() === 'service_worker'), 'the worker went to sleep');
    const page = await tb.tab('https://work.test/after-idle');
    await reportedLast('https://work.test/after-idle');
    void page;
  });
});

// ---------------------------------------------------------------------------
// 9. The worker dying

group('service worker death', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  const sites = ['x.com'];
  const wake = async () => {
    await until('the worker to reconnect', () => app.greeted.size > 0, 35000);
    await sleep(200);
  };

  await it('in a session: rules hold, the site stays blocked, and it reconnects', async () => {
    app.startSession({ preset: 'standard', sites });
    await until('rules', async () => (await tb.rules()).length === 1);
    assert(await tb.killWorker(), 'killed');
    assertEqual((await tb.rules()).length, 1, 'rules while it\'s dead');
    const hellos = app.messages('hello').length;
    const page = await tb.tab('https://x.com/while-dead');
    await waitBlocked(page);
    await wake();
    assert(app.messages('hello').length > hellos, 'a new hello');
    assertEqual((await tb.rules()).length, 1, 'rules after it woke');
  });

  await it('it comes back within the alarm\'s 30 s with nothing else to wake it', async () => {
    await tb.killWorker();
    const started = Date.now();
    await until('a new hello', () => app.greeted.size > 0, 45000);
    const took = Date.now() - started;
    console.log(`        reconnected after ${(took / 1000).toFixed(1)} s`);
    assert(took <= 35000, `took ${took} ms`);
    await sleep(200);
  });

  await it('a block page open across the death: its pass gets the tab through', async () => {
    await wake();
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/blocked-page');
    await waitBlocked(page);
    await until('the pass button', () => buttonFor(page, 'blockLetMeThrough'));
    await tb.killWorker();
    await sleep(300);
    const asked = app.messages('requestPass').length;
    await press(page, 'blockLetMeThrough');
    await waitAt(page, 'https://x.com/blocked-page', 6000);
    assertEqual(app.messages('requestPass').length, asked + 1, 'passes asked for');
    await until('the countdown', () => hasPill(page), 3000);
  });
  await it('a block page open across the death: "for work" gets the tab through', async () => {
    await wake();
    app.startSession({ preset: 'gentle', sites });
    const page = await tb.tab('https://x.com/work-death');
    await waitBlocked(page);
    await until('the for-work button', () => buttonFor(page, 'blockForWork'));
    await tb.killWorker();
    await sleep(300);
    await press(page, 'blockForWork');
    await waitAt(page, 'https://x.com/work-death', 6000);
  });
  await it('a block page open across the death never says FocusGuard isn\'t running', async () => {
    await wake();
    app.startSession({ preset: 'standard', sites });
    const page = await tb.tab('https://x.com/no-flash');
    await waitBlocked(page);
    await until('the pass button', () => buttonFor(page, 'blockLetMeThrough'));
    const wrong = await message(page, 'overNotRunning');
    await page.evaluate((text) => {
      window.flashed = false;
      new MutationObserver(() => { if (document.body.innerText.includes(text)) window.flashed = true; }).observe(document.body, { childList: true, subtree: true });
    }, wrong);
    await tb.killWorker();
    await wake();
    await sleep(800);
    assert(!(await page.evaluate(() => window.flashed)), 'it said so while the worker woke');
    assert(await buttonFor(page, 'blockLetMeThrough'), 'still the block page');
  });

  await it('a block page open across the death still follows the app: the session ends, it says so', async () => {
    await wake();
    app.startSession({ preset: 'standard', sites });
    const page = await tb.tab('https://x.com/following');
    await waitBlocked(page);
    await until('the pass button', () => buttonFor(page, 'blockLetMeThrough'));
    await tb.killWorker();
    await wake();
    app.endSession();
    const title = await message(page, 'overTitle');
    await until('the session-over view', async () => (await pageText(page)).includes(title), 5000);
  });

  await it('in a pass: the page stays, and the block comes back when it ends', { bug: 'B-worker-30s' }, async () => {
    await wake();
    app.startSession({ preset: 'gentle', sites });
    app.passMs = 6000;
    const page = await tb.tab('https://x.com/pass-death');
    await waitBlocked(page);
    await page.waitForSelector('.actions button');
    await press(page, 'blockLetMeThrough');
    await waitAt(page, 'https://x.com/pass-death');
    await until('the pill', () => hasPill(page), 3000);
    await tb.killWorker();
    const killedAt = Date.now();
    assertEqual((await tb.rules()).length, 0, 'the pass\'s rules while it\'s dead');
    await waitBlocked(page, 40000);
    console.log(`        the block returned ${((Date.now() - killedAt) / 1000).toFixed(1)} s after the kill (a 6 s pass)`);
    assert(Date.now() - killedAt <= 12000, `the pass ran on for ${Date.now() - killedAt} ms with a dead worker`);
    app.passMs = 120000;
  });

  await it('a limit: holds across the death, and comes off with extra time', async () => {
    app.endSession();
    app.set({ preset: 'gentle', limits: [REDDIT_LIMIT()] });
    await until('rule', async () => (await tb.rules()).length === 1);
    await tb.killWorker();
    const page = await tb.tab('https://reddit.com/limit-death');
    await waitBlocked(page);
    await wake();
    await page.waitForSelector('.limit-card');
    await press(page, 'limitMoreMinutes', 5);
    await waitAt(page, 'https://reddit.com/limit-death');
    app.set({ limits: [] });
  });

  await it('after waking, the app quitting still lets everything through', async () => {
    app.startSession({ preset: 'standard', sites });
    await until('rules', async () => (await tb.rules()).length === 1);
    await tb.killWorker();
    await app.stop();
    await tb.tab('https://work.test/wake');
    await until('the rules to clear', async () => (await tb.rules()).length === 0, 35000);
    const page = await tb.tab('https://x.com/free-now');
    assertEqual(page.url(), 'https://x.com/free-now', 'x.com with the app closed');
    await app.start();
    await tb.connected();
  });
});

group('the app closing and the browser restarting', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  const sites = ['x.com'];

  await it('the app quits: rules go at once, a blocked page offers the site', async () => {
    app.startSession({ preset: 'standard', sites });
    await until('rules', async () => (await tb.rules()).length === 1);
    const page = await tb.tab('https://x.com/quit');
    await waitBlocked(page);
    await page.waitForSelector('.actions button');
    await app.stop();
    await until('rules off', async () => (await tb.rules()).length === 0, 4000);
    const title = await message(page, 'overNotRunning');
    await until('the not-running view', async () => (await pageText(page)).includes(title));
    await shot(page, 'block-app-quit');
    const open = await buttonFor(page, 'overOpenHost', 'x.com');
    await press(page, 'overOpenHost', 'x.com');
    await waitAt(page, 'https://x.com/quit');
    const other = await tb.tab('https://x.com/other');
    assertEqual(other.url(), 'https://x.com/other', 'a new tab');
    const reply = await (await tb.tab(`${ORIGIN}/pages/popup.html`)).evaluate(() => chrome.runtime.sendMessage({ type: 'request', payload: { type: 'startSession', minutes: 25 } }));
    assertEqual(reply.ok, false, 'a request with the app closed');
    assertEqual(reply.error, 'notRunning', 'its error');
  });

  await it('the app comes back mid-session: blocking resumes', async () => {
    await app.start();
    app.startSession({ preset: 'standard', sites });
    await until('rules', async () => (await tb.rules()).length === 1, 15000);
    const page = await tb.tab('https://x.com/back');
    await waitBlocked(page);
  });
});

const BRANDED = /Google Chrome\.app/.test(CHROME);

group('browser restart', { browser: { loadByFlag: true }, skip: BRANDED }, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  await it('the session goes on: the rules come back', async () => {
    app.startSession({ preset: 'standard', sites: ['x.com'] });
    await until('rules', async () => (await tb.rules()).length === 1);
    const profile = tb.profile;
    await tb.browser.close();
    app.greeted.clear();
    const next = new TestBrowser({ puppeteer, chrome: CHROME, web, tmp, app, helper: HELPER, userDataDir: profile, loadByFlag: true });
    await next.open();
    try {
      await until('the worker', () => next.browser.targets().some((t) => t.type() === 'service_worker'), 15000);
      await next.connected();
      await until('rules', async () => (await next.rules()).length === 1, 5000);
      const page = await next.tab('https://x.com/restart');
      await waitBlocked(page);
    } finally {
      await next.close();
      tb.closed = true;
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    }
  });
});

// ---------------------------------------------------------------------------
// 10. Private windows

group('private windows, not allowed', { browser: { extraArgs: ['--incognito'] } }, async ({ tb, app, it }) => {
  // With --incognito the window the browser starts with is a private one.
  const [first] = await tb.browser.pages();
  await it('nothing about a private window reaches the app', async () => {
    await tb.connected();
    await first.goto('https://secret.test/private');
    await first.bringToFront();
    await sleep(800);
    assertEqual(reportsOf(app, 'https://secret.test/private').length, 0, 'reports of the private page');
    assert(!JSON.stringify(app.messages('tab')).includes('secret.test'), 'its address or title in a report');
  });
  await it('a blocked site loads there, as Options says it will', async () => {
    app.startSession({ preset: 'standard', sites: ['x.com'] });
    await until('rules', async () => (await tb.rules()).length === 1);
    await first.goto('https://x.com/private');
    assertEqual(first.url(), 'https://x.com/private', 'in a private window without access');
    app.endSession();
  });
});

group('private windows, allowed', { browser: { loadByFlag: true }, skip: BRANDED }, async ({ tb, app, it }) => {
  // Allowing them reloads the extension, and automation loses the reloaded
  // worker, so this allows them and then restarts the browser.
  await tb.connected();
  await tb.closeWelcome();
  const settings = await tb.browser.newPage();
  await settings.goto('chrome://extensions');
  await settings.evaluate((id) => chrome.developerPrivate.updateExtensionConfiguration({ extensionId: id, incognitoAccess: true }), new URL(ORIGIN).hostname);
  await sleep(500);
  await tb.browser.close();
  app.greeted.clear();
  await sleep(500);
  const next = await new TestBrowser({ puppeteer, chrome: CHROME, web, tmp, app, helper: HELPER, userDataDir: tb.profile, loadByFlag: true }).open();
  const privateTab = async (url) => {
    const before = new Set(next.browser.targets());
    const worker = await next.worker();
    await worker.evaluate((u) => { chrome.windows.create({ url: u, incognito: true, focused: true }); }, url);
    return until('the private tab', () => next.browser.targets().find((t) => !before.has(t) && t.type() === 'page'), 5000);
  };
  const frontTab = async () => {
    const worker = await next.worker();
    const [tab] = await worker.evaluate(() => chrome.tabs.query({ active: true, lastFocusedWindow: true }));
    return tab;
  };
  try {
    await next.connected();
    await it('the app hears they\'re allowed, and hears about private pages', async () => {
      assertEqual(app.messages('hello').at(-1).incognito, true, 'hello.incognito');
      await privateTab('https://secret.test/allowed');
      await until('the report', () => lastReport(app)?.url === 'https://secret.test/allowed', 4000);
    });
    await it('a blocked site is kept from loading', async () => {
      app.startSession({ preset: 'standard', sites: ['x.com'] });
      await until('rules', async () => (await next.rules()).length === 1);
      const since = Date.now();
      await privateTab('https://x.com/private');
      await sleep(1000);
      assert(!web.served('x.com', since), 'the site loaded');
    });
    await it('it shows the block page, not the browser\'s error page', { bug: 'B-incognito-pages' }, async () => {
      const target = next.browser.targets().find((t) => t.url().includes('x.com/private'));
      const page = await target.asPage();
      await shot(page, 'private-window-block');
      const text = await pageText(page);
      assert(!text.includes('ERR_BLOCKED_BY_CLIENT'), `the tab says: ${text.replace(/\s+/g, ' ').slice(0, 120)}`);
    });
    await it('Free: a paused private tab shows the paused page, not the browser\'s error page', { bug: 'B-incognito-pages' }, async () => {
      app.set({ plan: FREE });
      await sleep(300);
      await privateTab('https://free.test/pause-me');
      const report = await until('the report', () => reportsOf(app, 'https://free.test/pause-me').at(-1), 4000);
      app.sendAll({ type: 'pauseTab', rid: 'private', host: 'free.test', tabId: report.tab.tabId, fragment: `id=pp&host=free.test&url=${encodeURIComponent('https://free.test/pause-me')}&state=paused&ends=${Math.round(Date.now() / 1000) + 600}` });
      await until('the answer', () => app.messages('pauseResult').find((m) => m.rid === 'private'));
      await sleep(800);
      const tab = await frontTab();
      const target = next.browser.targets().find((t) => t.url() === tab.url);
      const text = await pageText(await target.asPage());
      assert(!text.includes('ERR_BLOCKED_BY_CLIENT'), `the tab says: ${text.replace(/\s+/g, ' ').slice(0, 120)}`);
    });
  } finally {
    await next.close();
    fs.rmSync(tb.profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    tb.closed = true;
  }
});

// ---------------------------------------------------------------------------
// 11. Languages

for (const lang of ['en', 'de', 'az']) {
  group(`language: ${lang}`, { browser: { lang } }, async ({ tb, app, it }) => {
    await tb.connected();
    const check = async (page, name) => {
      await sleep(250);
      const want = lang;
      const actual = await page.evaluate(() => document.documentElement.lang);
      assert(actual.startsWith(want), `<html lang> is ${actual}`);
      assertEqual((await badWords(page)).join(' / '), '', 'raw text');
      assertEqual((await clipped(page)).join(' / '), '', 'clipped text');
      await shot(page, `${lang}-${name}`);
    };
    await it('welcome', async () => {
      const target = await tb.browser.waitForTarget((t) => t.url().endsWith('pages/welcome.html'), { timeout: 10000 });
      const page = await target.asPage();
      await page.waitForSelector('button.big-btn');
      await check(page, 'welcome');
      await page.click('button.big-btn');
      await page.waitForSelector('.steps');
      await check(page, 'welcome-next');
      const skip = await buttonFor(page, 'welcomeSkip');
      if (skip) await skip.click();
      await page.waitForSelector('.summary');
      await check(page, 'welcome-done');
      await page.close();
    });
    const sites = ['x.com', 'reddit.com'];
    await it('popup', async () => {
      app.set({ plan: PRO, phase: 'ready', session: null });
      let page = await popup(tb);
      await page.waitForSelector('.start');
      await check(page, 'popup-ready');
      await page.close();
      app.startSession({ preset: 'strict', sites, parts: ['youtube.com/shorts'], backTo: 'Visual Studio Code' });
      page = await popup(tb);
      await page.waitForSelector('.blocked');
      await check(page, 'popup-strict');
      await page.close();
      app.set({ plan: FREE });
      page = await popup(tb);
      await page.waitForSelector('.clock-card');
      await check(page, 'popup-free');
      await page.close();
      app.startBreak();
      page = await popup(tb);
      await page.waitForSelector('.paused-card');
      await check(page, 'popup-break');
      await page.close();
      app.set({ plan: PRO });
    });
    await it('block pages', async () => {
      for (const preset of ['gentle', 'standard', 'strict']) {
        app.startSession({ preset, sites, parts: ['youtube.com/shorts'], backTo: 'Visual Studio Code' });
        await sleep(150);
        let page = await tb.tab('https://x.com/a');
        await waitBlocked(page);
        await page.waitForSelector('.actions button');
        await check(page, `block-site-${preset}`);
        await page.close();
        page = await tb.tab('https://youtube.com/shorts/a');
        await waitBlocked(page);
        await page.waitForSelector('.actions button');
        await check(page, `block-part-${preset}`);
        await page.close();
      }
      app.endSession();
    });
    await it('limit pages', async () => {
      for (const preset of ['gentle', 'standard', 'strict']) {
        app.set({ preset, limits: [REDDIT_LIMIT({ extraLeft: preset === 'gentle' ? 2 : preset === 'standard' ? 1 : 0 })] });
        await sleep(150);
        const page = await tb.tab('https://reddit.com/');
        await waitBlocked(page);
        await page.waitForSelector('.limit-card');
        await check(page, `block-limit-${preset}`);
        await page.close();
      }
      app.set({ limits: [], preset: 'standard' });
    });
    await it('paused page', async () => {
      const ends = Math.round(Date.now() / 1000) + 1800;
      for (const state of ['paused', 'queued', 'over', 'limit']) {
        const page = await tb.tab(`${BLOCK}?kind=paused#id=p&host=x.com&url=${encodeURIComponent('https://x.com/')}&state=${state}&ends=${ends}&minutes=30&back=Xcode`);
        await page.waitForSelector('.actions button');
        await check(page, `paused-${state}`);
        await page.close();
      }
    });
    await it('options', async () => {
      app.set({ plan: PRO, sites, parts: ['youtube.com/shorts'], limits: [REDDIT_LIMIT()] });
      const page = await tb.browser.newPage();
      await page.setViewport({ width: 1100, height: 900 });
      await page.goto(`${ORIGIN}/pages/options.html`);
      await page.waitForSelector('.panel');
      await check(page, 'options');
      app.set({ limits: [] });
    });
    await it('not running', async () => {
      await app.stop();
      const page = await popup(tb);
      const title = await message(page, 'appNotRunning');
      await until('the not-running card', async () => (await pageText(page)).includes(title));
      await check(page, 'popup-not-running');
      await app.start();
    });
  });
}

group('language: Azerbaijani with its catalog missing', { browser: { lang: 'az', extensionDir: 'NO_AZ' } }, async ({ tb, app, it }) => {
  await it('every page falls back to English, without errors', async () => {
    await tb.connected();
    const errors = [];
    const page = await popup(tb);
    page.on('pageerror', (e) => errors.push(e.message));
    await page.waitForSelector('.start');
    assert((await page.evaluate(() => document.documentElement.lang)).startsWith('en'), '<html lang> in English');
    assertEqual((await badWords(page)).join(' / '), '', 'raw text');
    assert((await pageText(page)).includes('FocusGuard'), 'the page');
    assertEqual(errors.join(', '), '', 'errors');
    void app;
  });
});

// ---------------------------------------------------------------------------
// 12. The extension's own network traffic

group('network', {}, async ({ tb, app, it }) => {
  await tb.connected();
  await tb.closeWelcome();
  await it('neither the worker nor the extension\'s pages ask anything of the network', async () => {
    const worker = await tb.worker();
    const seen = [];
    const client = worker.client;
    await client.send('Network.enable');
    client.on('Network.requestWillBeSent', (e) => seen.push(`worker: ${e.request.url}`));
    const watch = async (page) => {
      const cdp = await page.createCDPSession();
      await cdp.send('Network.enable');
      cdp.on('Network.requestWillBeSent', (e) => seen.push(`${page.url().split('/').pop()}: ${e.request.url}`));
      return cdp;
    };
    const walk = async (file) => {
      const page = await tb.browser.newPage();
      await watch(page);
      await page.goto(`${ORIGIN}/pages/${file}`);
      await sleep(400);
      return page;
    };
    await (await walk('welcome.html')).close();
    app.set({ plan: PRO, sites: ['x.com'], parts: ['youtube.com/shorts'], limits: [REDDIT_LIMIT()] });
    await (await walk('popup.html')).close();
    await (await walk('options.html')).close();
    app.startSession({ preset: 'gentle' });
    await sleep(200);
    await (await walk('block.html?kind=site&target=x.com#https://x.com/')).close();
    await (await walk('block.html?kind=limit&target=reddit.com#https://reddit.com/')).close();
    await tb.tab('https://work.test/page');
    await sleep(300);
    const outside = seen.filter((line) => !line.includes(`${ORIGIN}/`));
    assertEqual(outside.join('\n'), '', 'requests that left the extension');
    // Nothing seen has to mean nothing happened: a request from the worker does show.
    await worker.evaluate(() => fetch('https://beacon.test/canary', { mode: 'no-cors' }).catch(() => {}));
    await until('the watcher to see the worker\'s own request', () => seen.some((line) => line.includes('beacon.test/canary')), 3000);
    assert(seen.some((line) => line.includes('pages/popup.js')), 'the watcher saw the pages load');
    app.endSession();
  });
});

// ---------------------------------------------------------------------------

async function main() {
  puppeteer = await loadPuppeteer();
  tmp = tempDir();
  web = new Web();
  await web.start(makeCert(tmp));
  try {
    for (const g of groups.filter((one) => !GROUP || GROUP.test(one.name))) await runGroup(g);
  } finally {
    web.stop();
    fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  }
  if (LIST) process.exit(0);
  const count = (kind) => results.filter((r) => r[0] === kind).length;
  console.log(`\n${count('PASS')} passed, ${count('KNOWN')} known bugs, ${count('FIXED')} fixed, ${count('FAIL')} failed`);
  for (const r of results.filter((x) => x[0] === 'FAIL')) console.log(`FAIL  ${r[1]}: ${r[2]}\n      ${r[3]}`);
  process.exit(count('FAIL') ? 1 : 0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

