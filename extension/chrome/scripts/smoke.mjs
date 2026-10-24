#!/usr/bin/env node
// Loads the unpacked extension into a real Chrome with a throwaway profile,
// connects it through the real FocusGuardBrowserHelper to a fake app on a
// test socket, and walks the main flows: connect, tab reports, the popup's
// states, pausing a tab and giving it back, the block pages, options and
// first run. Saves a screenshot of each.
//
//   npm i puppeteer-core          (anywhere; or run from a folder that has it)
//   node scripts/smoke.mjs --helper /path/to/FocusGuard.app/Contents/Helpers/FocusGuardBrowserHelper
//
// Options: --chrome PATH (default: Google Chrome in /Applications)
//          --out DIR     (default: ./smoke-shots)
//          --headful     (watch it run)
//
// Branded Chrome ignores --load-extension since 137, so the extension goes
// in through puppeteer's pipe (Extensions.loadUnpacked).

import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const EXTENSION = path.resolve(here, '..');
const EXTENSION_ID = 'abeehapgjhkgbfokheomoahlgidgcoik';

const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const HELPER = arg('--helper');
const CHROME = arg('--chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
const OUT = path.resolve(arg('--out', 'smoke-shots'));
const HEADFUL = args.includes('--headful');

if (!HELPER || !fs.existsSync(HELPER)) {
  console.error('Pass --helper with the path to FocusGuardBrowserHelper (inside a built FocusGuard.app).');
  process.exit(2);
}

async function loadPuppeteer() {
  try {
    return (await import('puppeteer-core')).default;
  } catch {
    const require = createRequire(path.join(process.cwd(), 'noop.js'));
    return (await import(require.resolve('puppeteer-core'))).default;
  }
}

// ---------------------------------------------------------------------------
// A fake FocusGuard app on the helper's socket.

const SOCKET = `/tmp/fg-smoke-${process.pid}.sock`;
const received = [];
const sockets = new Set();
let server = null;
let appState = null;

function frame(object) {
  const body = Buffer.from(JSON.stringify(object));
  const head = Buffer.alloc(4);
  head.writeUInt32LE(body.length);
  return Buffer.concat([head, body]);
}

function sendAll(object) {
  for (const socket of sockets) socket.write(frame(object));
}

function onAppMessage(socket, message) {
  received.push(message);
  switch (message.type) {
    case 'hello':
      if (appState) socket.write(frame(appState));
      break;
    case 'classify':
      socket.write(frame({ type: 'reply', id: message.id, ok: true, result: { host: new URL(message.url).hostname, category: 'neutral' } }));
      break;
    case 'setCategory':
      socket.write(frame({ type: 'reply', id: message.id, ok: true, result: { host: new URL(message.url).hostname, category: message.category, ruleScope: message.scope } }));
      break;
    default:
      if (message.id) socket.write(frame({ type: 'reply', id: message.id, ok: true }));
  }
}

function startApp() {
  try { fs.unlinkSync(SOCKET); } catch { /* not there */ }
  server = net.createServer((socket) => {
    sockets.add(socket);
    let buffer = Buffer.alloc(0);
    socket.on('data', (data) => {
      buffer = Buffer.concat([buffer, data]);
      while (buffer.length >= 4) {
        const length = buffer.readUInt32LE(0);
        if (buffer.length < 4 + length) break;
        const message = JSON.parse(buffer.subarray(4, 4 + length).toString());
        buffer = buffer.subarray(4 + length);
        onAppMessage(socket, message);
      }
    });
    socket.on('close', () => sockets.delete(socket));
    socket.on('error', () => sockets.delete(socket));
  });
  return new Promise((resolve) => server.listen(SOCKET, resolve));
}

function stopApp() {
  for (const socket of sockets) socket.destroy();
  sockets.clear();
  return new Promise((resolve) => server.close(resolve));
}

function setState(state) {
  appState = state;
  sendAll(state);
}

async function waitFor(what, predicate, timeout = 15000) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    const found = predicate();
    if (found) return found;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`timed out waiting for ${what}`);
}

// ---------------------------------------------------------------------------
// States

const now = Date.now();
const base = JSON.parse(fs.readFileSync(path.join(EXTENSION, 'test/fixtures/state-focusing.json')));
const shift = now - base.session.asOf;
const focusingPro = {
  ...base,
  session: { ...base.session, startedAt: base.session.startedAt + shift, endsAt: base.session.endsAt + shift, asOf: now },
  blocking: { ...base.blocking, passes: [] },
};
const focusingFree = { ...focusingPro, plan: { tier: 'free', pro: false } };
const ready = { ...focusingFree, phase: 'ready', session: undefined };
const onBreak = {
  ...focusingFree, phase: 'break', session: undefined,
  break: { startedAt: now - 138000, endsAt: now + 462000, plannedSeconds: 600, after: 'Locked-in Deep Dive · 50 min', canEndEarly: true },
};
const strict = {
  ...focusingPro,
  preset: 'strict',
  policy: { allowsPass: false, passWaitSeconds: 0, passSeconds: 120, forWorkWaitSeconds: 10, locksDuringSession: true,
    extraTime: { minutes: 5, timesPerDay: 0, waitSeconds: 0 }, limitChangesWaitForTomorrow: true },
  blocking: { ...focusingPro.blocking, lockedUntil: focusingPro.session.endsAt },
};
const withLimit = {
  ...focusingPro,
  blocking: { ...focusingPro.blocking, limits: [{ site: 'reddit.com', minutes: 30, usedSeconds: 1800, reached: true, extraLeft: 1, visits: 6, lastVisitAt: now - 3600000 }] },
};

// ---------------------------------------------------------------------------

const results = [];
async function step(name, body) {
  try {
    await body();
    results.push(['PASS', name]);
    console.log(`PASS  ${name}`);
  } catch (error) {
    results.push(['FAIL', name, error.message]);
    console.log(`FAIL  ${name}: ${error.message}`);
  }
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const puppeteer = await loadPuppeteer();
  await startApp();
  setState(ready);

  // A profile of our own, with the host manifest where Chrome looks for it.
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'fg-smoke-profile-'));
  const hosts = path.join(profile, 'NativeMessagingHosts');
  fs.mkdirSync(hosts, { recursive: true });
  fs.writeFileSync(path.join(hosts, 'com.anar.focusguard.json'), JSON.stringify({
    name: 'com.anar.focusguard', description: 'FocusGuard', path: path.resolve(HELPER), type: 'stdio',
    allowed_origins: [`chrome-extension://${EXTENSION_ID}/`],
  }));

  // Two plain pages to visit.
  const web = http.createServer((req, res) => {
    const title = req.url.startsWith('/work') ? 'Pull requests · focusguard' : 'Home / Distracting';
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(`<!doctype html><title>${title}</title><body style="font:16px system-ui;padding:40px"><h1>${title}</h1></body>`);
  });
  await new Promise((r) => web.listen(0, '127.0.0.1', r));
  const site = `http://127.0.0.1:${web.address().port}`;

  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: !HEADFUL,
    pipe: true,
    enableExtensions: [EXTENSION],
    userDataDir: profile,
    env: { ...process.env, FOCUSGUARD_BROWSER_SOCKET: SOCKET },
    args: ['--no-first-run', '--no-default-browser-check', '--window-size=1280,800'],
    defaultViewport: null,
  });

  const shot = async (page, name, { width = 1280, height = 800, dark = false } = {}) => {
    await page.setViewport({ width, height });
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: dark ? 'dark' : 'light' }]);
    await new Promise((r) => setTimeout(r, 400));
    await page.screenshot({ path: path.join(OUT, `${name}.png`) });
  };
  const extPage = async (file, { width = 1280, height = 800 } = {}) => {
    const page = await browser.newPage();
    await page.setViewport({ width, height });
    await page.goto(`chrome-extension://${EXTENSION_ID}/pages/${file}`);
    return page;
  };

  try {
    await step('the extension reaches the app through the helper', async () => {
      const hello = await waitFor('helperHello', () => received.find((m) => m.type === 'helperHello'));
      if (hello.origin !== `chrome-extension://${EXTENSION_ID}/`) throw new Error(`origin ${hello.origin}`);
      if (!hello.browser) throw new Error('the helper did not name the browser');
      console.log(`      browser: ${hello.browser}`);
      await waitFor('hello', () => received.find((m) => m.type === 'hello'));
    });

    await step('first run opens and walks through', async () => {
      const target = await browser.waitForTarget((t) => t.url().endsWith('pages/welcome.html'), { timeout: 10000 });
      const page = await target.asPage();
      await shot(page, 'first-1-welcome');
      await page.click('button.big-btn');
      await page.waitForSelector('.steps');
      await shot(page, 'first-2-pin');
      await page.evaluate(() => [...document.querySelectorAll('a')].find((a) => a.textContent.includes('Skip'))?.click());
      await page.waitForFunction(() => document.body.textContent.includes("You're set."));
      await shot(page, 'first-3-done');
      await page.close();
    });

    let tabId = null;
    const work = await browser.newPage();
    await step('the tab in front is reported', async () => {
      await work.goto(`${site}/work`);
      await work.bringToFront();
      const report = await waitFor('tab report', () => received.filter((m) => m.type === 'tab').reverse()
        .find((m) => m.tab?.url === `${site}/work`));
      if (report.tab.title !== 'Pull requests · focusguard') throw new Error(`title ${report.tab.title}`);
      tabId = report.tab.tabId;
    });

    await step('popup: ready, with the category menu', async () => {
      const popup = await extPage('popup.html', { width: 340, height: 640 });
      await popup.waitForSelector('.start');
      await shot(popup, 'popup-ready', { width: 340, height: 640 });
      await shot(popup, 'popup-ready-dark', { width: 340, height: 640, dark: true });
      await popup.close();
    });

    await step('popup: focusing on the free plan, then Pro', async () => {
      setState(focusingFree);
      const popup = await extPage('popup.html', { width: 340, height: 700 });
      await popup.waitForSelector('.clock-card');
      await shot(popup, 'popup-focusing-free', { width: 340, height: 700 });
      setState(focusingPro);
      await popup.waitForSelector('.plan-card .btn-primary, .blocked');
      await shot(popup, 'popup-focusing-pro', { width: 340, height: 700 });
      await popup.close();
    });

    await step('popup: break', async () => {
      setState(onBreak);
      const popup = await extPage('popup.html', { width: 340, height: 640 });
      await popup.waitForSelector('.paused-card');
      await shot(popup, 'popup-break', { width: 340, height: 640 });
      await popup.close();
    });

    await step('a free tab pauses, moves through its states and comes back', async () => {
      setState(focusingFree);
      const page = await browser.newPage();
      await page.goto(`${site}/`);
      await page.bringToFront();
      const report = await waitFor('distracting tab report', () => received.filter((m) => m.type === 'tab').reverse()
        .find((m) => m.tab?.url === `${site}/`));
      // What the app's TabPauseCoordinator sends: paused.html's own fields.
      const ends = Math.round(focusingFree.session.endsAt / 1000);
      const fields = (state) => `id=pause-1&host=127.0.0.1&url=${encodeURIComponent(`${site}/`)}&state=${state}&ends=${ends}&back=Xcode`;
      sendAll({ type: 'pauseTab', rid: 'r1', host: '127.0.0.1', tabId: report.tab.tabId, fragment: fields('paused') });
      const result = await waitFor('pauseResult', () => received.find((m) => m.type === 'pauseResult' && m.rid === 'r1'));
      if (!result.ok) throw new Error('the extension did not pause the tab');
      await page.waitForFunction(() => location.href.includes('pages/block.html?kind=paused#id=pause-1&'), { timeout: 10000 });
      await page.waitForSelector('.ring');
      await shot(page, 'block-paused-free');
      await shot(page, 'block-paused-free-dark', { dark: true });

      // "Reopen after the session", answered by the app moving the page on.
      await page.evaluate(() => [...document.querySelectorAll('button')].find((b) => b.textContent.includes('Reopen after'))?.click());
      await waitFor('tabAction', () => received.find((m) => m.type === 'tabAction' && m.action === 'reopenLater' && m.pauseId === 'pause-1'));
      sendAll({ type: 'redirectTab', pauseId: 'pause-1', fragment: fields('queued') });
      await page.waitForFunction(() => document.body.textContent.includes('will reopen when your session ends'));
      await shot(page, 'block-paused-queued');

      sendAll({ type: 'redirectTab', pauseId: 'pause-1', fragment: fields('over') });
      await page.waitForFunction(() => document.body.textContent.includes('Your session is over'));
      await shot(page, 'block-paused-over');

      sendAll({ type: 'redirectTab', pauseId: 'pause-1', url: `${site}/` });
      await page.waitForFunction((u) => location.href === u, { timeout: 10000 }, `${site}/`);
      await page.close();
    });

    await step('Pro block pages: Standard, Strict, a part of a site, a daily limit', async () => {
      setState(focusingPro);
      const page = await extPage('block.html?kind=site&target=x.com#https://x.com/home');
      await page.waitForSelector('.ring');
      await shot(page, 'block-site-standard');
      setState(strict);
      await page.waitForFunction(() => document.body.textContent.includes('stays closed'));
      await shot(page, 'block-site-strict-dark', { dark: true });
      setState(focusingPro);
      await page.goto(`chrome-extension://${EXTENSION_ID}/pages/block.html?kind=part&target=youtube.com%2Fshorts#https://www.youtube.com/shorts/abc`);
      await page.waitForSelector('.ring');
      await shot(page, 'block-part');
      setState(withLimit);
      await page.goto(`chrome-extension://${EXTENSION_ID}/pages/block.html?kind=limit&target=reddit.com#https://www.reddit.com/`);
      await page.waitForSelector('.limit-card');
      await shot(page, 'block-limit');
      if (!received.some((m) => m.type === 'blockedVisit')) throw new Error('no blockedVisit sent');
      await page.close();
    });

    await step('options: free and Pro', async () => {
      setState(focusingFree);
      const page = await extPage('options.html', { width: 1100, height: 900 });
      await page.waitForSelector('.panel');
      await shot(page, 'options-free-dark', { width: 1100, height: 900, dark: true });
      setState(focusingPro);
      await page.waitForFunction(() => document.body.textContent.includes('Decide YouTube video by video'));
      await shot(page, 'options-pro', { width: 1100, height: 900 });
      await page.close();
    });

    await step('the popup changes a category and starts a session', async () => {
      setState(ready);
      await work.bringToFront();
      // The popup opened as a tab reports itself as the page; the request
      // path is what's under test here.
      const popup = await extPage('popup.html', { width: 340, height: 640 });
      await popup.waitForSelector('.start');
      await popup.evaluate(() => chrome.runtime.sendMessage({ type: 'request', payload: { type: 'setCategory', url: 'https://medium.com/@ann/a', scope: 'page', category: 'distracting' } }));
      await waitFor('setCategory', () => received.find((m) => m.type === 'setCategory' && m.scope === 'page'));
      await popup.click('.start .btn-primary');
      await waitFor('startSession', () => received.find((m) => m.type === 'startSession' && m.minutes));
      await popup.close();
    });

    await step('popup: FocusGuard not running', async () => {
      await stopApp();
      const popup = await extPage('popup.html', { width: 340, height: 600 });
      await popup.waitForFunction(() => document.body.textContent.includes("FocusGuard isn't running"), { timeout: 10000 });
      await shot(popup, 'popup-not-running', { width: 340, height: 600 });
      await popup.close();
    });
  } finally {
    await browser.close();
    web.close();
    try { await stopApp(); } catch { /* already stopped */ }
    fs.rmSync(profile, { recursive: true, force: true });
  }

  const failed = results.filter((r) => r[0] === 'FAIL');
  console.log(`\n${results.length - failed.length} passed, ${failed.length} failed. Screenshots in ${OUT}`);
  process.exit(failed.length ? 1 : 0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
