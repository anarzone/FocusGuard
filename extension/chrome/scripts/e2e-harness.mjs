// The pieces scripts/e2e.mjs drives the extension with: a fake FocusGuard app,
// a stand-in native-messaging host, a local web server that answers for every
// host name, and a throwaway browser.
//
// Nothing here can reach the real app: the stand-in host only ever connects to
// the fake app's socket, the profile lives in a temp folder (so the owner's
// host manifests are never read), and every host name resolves to the local
// server, so no test traffic leaves the Mac.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const EXTENSION = path.resolve(here, '..');
export const EXTENSION_ID = 'abeehapgjhkgbfokheomoahlgidgcoik';
export const ORIGIN = `chrome-extension://${EXTENSION_ID}`;

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Waits for an async predicate to give something truthy.
export async function until(what, predicate, timeout = 10000, every = 100) {
  const end = Date.now() + timeout;
  let last = null;
  while (Date.now() < end) {
    try {
      const value = await predicate();
      if (value) return value;
      last = null;
    } catch (error) { last = error; }
    await sleep(every);
  }
  throw new Error(`timed out waiting for ${what}${last ? ` (${last.message})` : ''}`);
}

export async function loadPuppeteer() {
  try {
    return (await import('puppeteer-core')).default;
  } catch {
    const require = createRequire(path.join(process.cwd(), 'noop.js'));
    return (await import(require.resolve('puppeteer-core'))).default;
  }
}

// ---------------------------------------------------------------------------
// The app's rules for each preset, copied from FocusGuard/Intervention/OverridePolicy.swift.

export const POLICY = {
  gentle: {
    allowsPass: true, passWaitSeconds: 0, passSeconds: 120, forWorkWaitSeconds: 0, locksDuringSession: false,
    extraTime: { minutes: 5, timesPerDay: 3, waitSeconds: 0 }, limitChangesWaitForTomorrow: false,
  },
  standard: {
    allowsPass: true, passWaitSeconds: 5, passSeconds: 120, forWorkWaitSeconds: 0, locksDuringSession: false,
    extraTime: { minutes: 5, timesPerDay: 1, waitSeconds: 5 }, limitChangesWaitForTomorrow: false,
  },
  strict: {
    allowsPass: false, passWaitSeconds: 0, passSeconds: 120, forWorkWaitSeconds: 10, locksDuringSession: true,
    extraTime: { minutes: 5, timesPerDay: 0, waitSeconds: 0 }, limitChangesWaitForTomorrow: true,
  },
};

export const FREE = { tier: 'free', pro: false, features: { blockInBrowser: false, partsOfSites: false, youtubePerVideo: false, unlimitedLimits: false } };
export const PRO = { tier: 'pro', pro: true, features: { blockInBrowser: true, partsOfSites: true, youtubePerVideo: true, unlimitedLimits: true } };
export const TRIAL = { tier: 'trial', pro: true, trialDaysLeft: 5, features: PRO.features };

// ---------------------------------------------------------------------------
// A fake FocusGuard app. It answers the way FocusGuard/Extension/ExtensionBridge.swift
// does: the same replies, a push after every message, passes that run out on a
// timer, and one state per greeted client.

export class FakeApp {
  constructor(socketPath) {
    this.socketPath = socketPath;
    this.received = [];
    this.sockets = new Set();
    this.server = null;
    this.greeted = new Set();
    this.plan = PRO;
    this.preset = 'standard';
    this.phase = 'ready';
    this.session = null;
    this.breakInfo = null;
    this.recap = null;
    this.sites = [];
    this.parts = [];
    this.limits = [];
    this.passes = new Map();
    this.allowed = new Set();
    this.stoppedVisits = 0;
    this.pauseTab = true;
    this.today = { focusSeconds: 3600, goalMinutes: 240 };
    this.passMs = 120000;          // how long a pass lasts; tests shorten it
    this.silent = false;           // an app that has stopped pushing state
    this.backToWorkApp = null;     // the focus app "Back to …" brings forward
    this.lastSent = null;
    this.lastHard = null;
    this.lastSentAt = 0;
    this.timer = null;
  }

  start() {
    try { fs.unlinkSync(this.socketPath); } catch { /* not there */ }
    this.server = net.createServer((socket) => {
      this.sockets.add(socket);
      let buffer = Buffer.alloc(0);
      socket.on('data', (data) => {
        buffer = Buffer.concat([buffer, data]);
        while (buffer.length >= 4) {
          const length = buffer.readUInt32LE(0);
          if (buffer.length < 4 + length) break;
          const message = JSON.parse(buffer.subarray(4, 4 + length).toString());
          buffer = buffer.subarray(4 + length);
          this.onMessage(socket, message);
        }
      });
      const gone = () => { this.sockets.delete(socket); this.greeted.delete(socket); };
      socket.on('close', gone);
      socket.on('error', gone);
    });
    this.timer = setInterval(() => this.tick(), 500);
    return new Promise((resolve) => this.server.listen(this.socketPath, resolve));
  }

  stop() {
    clearInterval(this.timer);
    for (const socket of this.sockets) socket.destroy();
    this.sockets.clear();
    this.greeted.clear();
    const server = this.server;
    this.server = null;
    return new Promise((resolve) => (server ? server.close(() => resolve()) : resolve()));
  }

  // --- what tests set ------------------------------------------------------

  startSession({ preset = this.preset, name = 'Evening focus', minutes = 50, backTo = null, sites, parts } = {}) {
    const now = Date.now();
    this.preset = preset;
    this.phase = 'focusing';
    this.passes.clear();
    this.allowed.clear();
    this.stoppedVisits = 0;
    this.backToWorkApp = backTo;
    if (sites) this.sites = sites;
    if (parts) this.parts = parts;
    this.session = { name, startedAt: now - 60000, plannedMinutes: minutes, pausedAt: null, backTo };
    this.push(true);
  }

  endSession() {
    this.phase = 'ready';
    this.session = null;
    this.passes.clear();
    this.allowed.clear();
    this.push(true);
  }

  pauseSession() {
    this.phase = 'paused';
    this.session.pausedAt = Date.now();
    this.push(true);
  }

  startBreak() {
    const now = Date.now();
    this.phase = 'break';
    this.session = null;
    this.breakInfo = { startedAt: now - 60000, endsAt: now + 540000, plannedSeconds: 600, after: 'Evening focus · 50 min', canEndEarly: true };
    this.push(true);
  }

  // Sets fields and sends the new state.
  set(fields) {
    Object.assign(this, fields);
    this.push(true);
  }

  sendAll(message) {
    for (const socket of this.greeted) socket.write(frame(message));
  }

  dropClients() {
    for (const socket of this.sockets) socket.destroy();
  }

  messages(type) {
    return this.received.filter((m) => m.type === type);
  }

  // --- the state, as ExtensionBridge.makeState builds it ---------------------

  makeState(now = Date.now()) {
    const livePasses = [...this.passes.entries()].filter(([, until]) => until > now)
      .map(([host, until]) => ({ host, until })).sort((a, b) => (a.host < b.host ? -1 : 1));
    const state = {
      type: 'state', v: 1, app: { version: '1.1-test' }, plan: this.plan, preset: this.preset,
      policy: POLICY[this.preset], today: this.today, phase: this.phase,
      blocking: {
        pauseTab: this.pauseTab, sites: this.sites, parts: this.parts, limits: this.limits,
        passes: livePasses, allowed: [...this.allowed].sort(),
      },
    };
    if (this.session) {
      const s = this.session;
      const paused = this.phase === 'paused';
      const startedAt = s.startedAt;
      const planned = s.plannedMinutes;
      const asOf = paused ? s.pausedAt : now;
      state.session = {
        name: s.name, startedAt, plannedMinutes: planned ?? undefined,
        endsAt: !paused && planned ? startedAt + planned * 60000 : undefined,
        elapsedSeconds: Math.floor((asOf - startedAt) / 1000), asOf: now, paused,
        segments: s.segments || [['f', 60]], focusSeconds: 60, driftSeconds: 0, otherSeconds: 0,
        stoppedVisits: this.stoppedVisits, backTo: s.backTo ?? undefined,
      };
      if (POLICY[this.preset].locksDuringSession && state.session.endsAt) state.blocking.lockedUntil = state.session.endsAt;
    }
    if (this.phase === 'break') state.break = this.breakInfo;
    if (this.phase === 'complete') state.recap = this.recap;
    return state;
  }

  hardPart(state) {
    const hard = JSON.parse(JSON.stringify(state));
    hard.today.focusSeconds = 0;
    if (hard.session) Object.assign(hard.session, { elapsedSeconds: 0, asOf: 0, segments: [], focusSeconds: 0, driftSeconds: 0, otherSeconds: 0 });
    return JSON.stringify(hard);
  }

  // ExtensionBridge.pushIfChanged.
  push(force) {
    if (this.silent || !this.greeted.size) return;
    const now = Date.now();
    const state = this.makeState(now);
    const hard = this.hardPart(state);
    const text = JSON.stringify(state);
    if (text === this.lastSent) return;
    if (!force && hard === this.lastHard && now - this.lastSentAt < 15000) return;
    this.lastSent = text;
    this.lastHard = hard;
    this.lastSentAt = now;
    this.sendAll(state);
  }

  tick() {
    const now = Date.now();
    for (const [host, until] of this.passes) if (until <= now) this.passes.delete(host);
    this.push(false);
  }

  // --- answers ---------------------------------------------------------------

  onMessage(socket, m) {
    this.received.push({ ...m, at: Date.now() });
    const reply = (fields = {}) => socket.write(frame({ type: 'reply', id: m.id, ok: !fields.error, ...fields }));
    switch (m.type) {
      case 'helperHello':
        break;
      case 'hello':
        this.greeted.add(socket);
        socket.write(frame(this.makeState()));
        break;
      case 'classify': case 'setCategory': {
        const host = new URL(m.url).hostname.replace(/^www\./, '');
        reply({ result: { host, category: m.category || 'neutral', ruleScope: m.scope } });
        break;
      }
      case 'startSession':
        if (this.session) reply({ error: 'alreadyRunning' });
        else if (this.phase === 'break') reply({ error: 'onBreak' });
        else { reply(); this.startSession({ minutes: m.minutes }); }
        break;
      case 'extendBreak': case 'endBreak':
        reply(this.phase === 'break' ? {} : { error: 'noBreak' });
        break;
      case 'backToWork':
        reply({ result: this.backToWorkApp ? { app: this.backToWorkApp } : {} });
        break;
      case 'requestPass':
        if (!this.plan.features.blockInBrowser) reply({ error: 'notPro' });
        else if (!this.session) reply({ error: 'noSession' });
        else if (!POLICY[this.preset].allowsPass) reply({ error: 'strict' });
        else {
          const until = Date.now() + this.passMs;
          this.passes.set(String(m.host).toLowerCase(), until);
          reply({ result: { until } });
        }
        break;
      case 'allowForWork':
        if (!this.session) reply({ error: 'noSession' });
        else { this.allowed.add(String(m.host).toLowerCase()); reply(); }
        break;
      case 'requestExtraTime': {
        const limit = this.limits.find((l) => l.site === m.site || String(m.site).endsWith(`.${l.site}`));
        const extra = POLICY[this.preset].extraTime;
        if (!limit) reply({ error: 'noLimit' });
        else if (extra.timesPerDay <= 0 || limit.extraLeft <= 0) reply({ error: 'notAllowed' });
        else {
          limit.extraLeft -= 1;
          limit.minutes += extra.minutes;
          limit.reached = false;
          reply();
        }
        break;
      }
      case 'blockedVisit':
        if (this.session) this.stoppedVisits += 1;
        break;
      case 'tabAction':
        reply();
        break;
      default:
        if (m.id) reply();
    }
    this.push(true);
  }
}

export function frame(object) {
  const body = Buffer.from(JSON.stringify(object));
  const head = Buffer.alloc(4);
  head.writeUInt32LE(body.length);
  return Buffer.concat([head, body]);
}

// ---------------------------------------------------------------------------
// A stand-in for FocusGuardBrowserHelper: the same relay and the same answers
// while the app is closed (FocusGuardBrowserHelper/main.swift), written for
// Node and able to reach nothing but the socket it's given.

const STAND_IN_HOST = (socketPath, logPath) => `#!${process.execPath}
const net = require('node:net');
const fs = require('node:fs');
const SOCKET = ${JSON.stringify(socketPath)};
const LOG = ${JSON.stringify(logPath)};
const log = (t) => { try { fs.appendFileSync(LOG, Date.now() + ' ' + t + '\\n'); } catch {} };
log('start ' + process.pid);
function frame(o) { const b = Buffer.isBuffer(o) ? o : Buffer.from(JSON.stringify(o)); const h = Buffer.alloc(4); h.writeUInt32LE(b.length); return Buffer.concat([h, b]); }
let sock = null, reported = null, retry = null, settled = false, early = [];
// The real helper tries the socket before it reads anything from the browser.
function settle() { settled = true; for (const body of early.splice(0)) fromExtension(body); }
function toExt(o) { process.stdout.write(frame(o)); }
function status(running, force) { if (!force && reported === running) return; reported = running; toExt({ type: 'appStatus', running }); }
function keepTrying() { if (!retry) retry = setInterval(connect, 2000); }
function connect() {
  const s = net.createConnection(SOCKET);
  s.once('connect', () => {
    sock = s;
    clearInterval(retry); retry = null;
    s.write(frame({ type: 'helperHello', browser: 'com.google.Chrome', origin: process.argv.slice(2).find((a) => a.startsWith('chrome-extension://')) }));
    status(true);
    settle();
  });
  let buf = Buffer.alloc(0);
  s.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 4) {
      const n = buf.readUInt32LE(0);
      if (buf.length < 4 + n) break;
      process.stdout.write(frame(buf.subarray(4, 4 + n)));
      buf = buf.subarray(4 + n);
    }
  });
  const gone = () => {
    if (sock === s) sock = null;
    if (!sock) { status(false); keepTrying(); settle(); }
    s.destroy();
  };
  s.on('error', gone);
  s.on('close', gone);
}
connect();
let inbuf = Buffer.alloc(0);
process.stdin.on('data', (d) => {
  inbuf = Buffer.concat([inbuf, d]);
  while (inbuf.length >= 4) {
    const n = inbuf.readUInt32LE(0);
    if (inbuf.length < 4 + n) break;
    const body = inbuf.subarray(4, 4 + n);
    inbuf = inbuf.subarray(4 + n);
    if (settled) fromExtension(body); else early.push(body);
  }
});
function fromExtension(body) {
  if (sock) { sock.write(frame(body)); return; }
  let m = null; try { m = JSON.parse(body); } catch { return; }
  log('closed: ' + m.type);
  if (m.type === 'hello') status(false, true);
  else if (m.type !== 'openApp' && m.id) toExt({ type: 'reply', id: m.id, ok: false, error: 'notRunning' });
}
process.stdin.on('end', () => { log('exit'); process.exit(0); });
process.stdin.on('close', () => { log('exit'); process.exit(0); });
`;

// ---------------------------------------------------------------------------
// A web server for every host name. The browser maps all names to it, so
// x.com here is this page, and nothing leaves the Mac. http and https share
// the one port, because the browser's mapping can't tell them apart.

export class Web {
  constructor() {
    this.requests = [];
  }

  page(title, body = '', head = '') {
    return `<!doctype html><meta charset="utf-8"><title>${title}</title>${head}<body style="font:16px system-ui;padding:40px;min-height:2000px"><h1>${title}</h1>${body}</body>`;
  }

  handle(req, res) {
    const host = (req.headers.host || '').split(':')[0];
    const url = new URL(req.url, 'http://x');
    this.requests.push({ host, path: req.url, at: Date.now(), secure: !!req.socket.encrypted, headers: req.headers });
    const send = (html, status = 200, headers = {}) => {
      res.writeHead(status, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', ...headers });
      res.end(html);
    };
    if (url.pathname === '/favicon.ico') { res.writeHead(404); res.end(); return; }
    if (url.pathname === '/cacheable') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'max-age=600' });
      res.end(this.page(`${host}${url.pathname}`));
      return;
    }
    if (url.pathname === '/slow') {
      // Headers now, the page later: stays "loading" for `ms`.
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.write(`<!doctype html><meta charset="utf-8"><title>Slow ${host}</title><h1>loading…</h1>`);
      setTimeout(() => res.end('<p>done</p>'), Number(url.searchParams.get('ms') || 2000));
      return;
    }
    if (url.pathname === '/redirect') { send('', 302, { location: url.searchParams.get('to') }); return; }
    if (url.pathname === '/jsredirect') { send(this.page(`Redirecting ${host}`, `<script>location.replace(${JSON.stringify(url.searchParams.get('to'))})</script>`)); return; }
    if (url.pathname === '/closes') { send(this.page(`Closing ${host}`, '<script>window.close()</script>')); return; }
    if (url.pathname === '/pwa') {
      // A site with its own service worker, the way x.com, reddit.com and youtube.com have.
      send(this.page(`${host}/pwa`, `<script>navigator.serviceWorker.register('/pwa-sw.js');fetch('https://beacon.test/ran?from=network',{mode:'no-cors'}).catch(()=>{});</script>`));
      return;
    }
    if (url.pathname === '/pwa-sw.js') {
      res.writeHead(200, { 'content-type': 'text/javascript', 'cache-control': 'no-store' });
      res.end(`self.addEventListener('install',()=>self.skipWaiting());
        self.addEventListener('activate',(e)=>e.waitUntil(clients.claim()));
        self.addEventListener('fetch',(e)=>{ if (e.request.mode==='navigate') e.respondWith(new Response("<!doctype html><title>From the site's worker</title><h1>From the site's worker</h1><script>fetch('https://beacon.test/ran?from=worker',{mode:'no-cors'}).catch(()=>{})</script>",{headers:{'content-type':'text/html'}})); });`);
      return;
    }
    if (url.pathname === '/watch' || url.pathname.startsWith('/live/')) {
      send(this.page('A video - YouTube', `
        <ytd-video-owner-renderer><div id="channel-name"><a>Some Channel</a></div></ytd-video-owner-renderer>
        <h1 class="ytd-watch-metadata"><yt-formatted-string>The video title</yt-formatted-string></h1>`));
      return;
    }
    send(this.page(`${host}${url.pathname === '/' ? '' : url.pathname}`, `<p id="where">${req.url}</p>`));
  }

  async start(cert) {
    const plain = http.createServer((req, res) => this.handle(req, res));
    const secure = https.createServer(cert, (req, res) => this.handle(req, res));
    const listen = (server) => new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
    const [plainPort, securePort] = [await listen(plain), await listen(secure)];
    this.inner = [plain, secure];
    this.server = net.createServer((socket) => {
      socket.on('error', () => {});
      socket.once('data', (data) => {
        // A TLS handshake starts with 0x16.
        const inner = net.connect(data[0] === 0x16 ? securePort : plainPort, '127.0.0.1', () => {
          inner.write(data);
          socket.pipe(inner);
          inner.pipe(socket);
        });
        inner.on('error', () => socket.destroy());
      });
    });
    await new Promise((resolve) => this.server.listen(0, '127.0.0.1', resolve));
    this.port = this.server.address().port;
  }

  stop() {
    this.server?.close();
    for (const server of this.inner || []) server.close();
  }

  // Every host name the browser asked this server for, past `since`.
  hosts(since = 0) {
    return [...new Set(this.requests.filter((r) => r.at >= since).map((r) => r.host))];
  }

  // Whether the server was asked for this address since `since`.
  served(host, since = 0) {
    return this.requests.some((r) => r.at >= since && r.host === host);
  }
}

// A throwaway certificate; the browser is told to ignore whose it is.
export function makeCert(dir) {
  const key = path.join(dir, 'key.pem');
  const cert = path.join(dir, 'cert.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=focusguard-e2e', '-keyout', key, '-out', cert, '-days', '2'], { stdio: 'ignore' });
  return { key: fs.readFileSync(key), cert: fs.readFileSync(cert) };
}

// ---------------------------------------------------------------------------
// A throwaway browser with the extension in it.

export class TestBrowser {
  constructor({ puppeteer, chrome, web, tmp, app = null, helper = null, helperMissing = false, lang = null, extensionDir = EXTENSION, loadByFlag = false, headful = false, extraArgs = [], userDataDir = null, netlog = null }) {
    Object.assign(this, { puppeteer, chrome, web, tmp, app, helper, helperMissing, lang, extensionDir, loadByFlag, headful, extraArgs, userDataDir, netlog });
    this.closed = false;
  }

  async open() {
    this.profile = this.userDataDir || fs.mkdtempSync(path.join(this.tmp, 'profile-'));
    const hosts = path.join(this.profile, 'NativeMessagingHosts');
    fs.mkdirSync(hosts, { recursive: true });
    const socket = this.app?.socketPath || path.join(this.tmp, 'no-app.sock');
    this.hostLog = path.join(this.tmp, `host-${path.basename(this.profile)}.log`);
    if (!this.helperMissing) {
      let helperPath = this.helper;
      if (!helperPath) {
        helperPath = path.join(this.tmp, `host-${path.basename(this.profile)}.js`);
        fs.writeFileSync(helperPath, STAND_IN_HOST(socket, this.hostLog), { mode: 0o755 });
      }
      fs.writeFileSync(path.join(hosts, 'com.anar.focusguard.json'), JSON.stringify({
        name: 'com.anar.focusguard', description: 'FocusGuard', path: helperPath, type: 'stdio',
        allowed_origins: [`${ORIGIN}/`],
      }));
    } else {
      fs.rmSync(path.join(hosts, 'com.anar.focusguard.json'), { force: true });
    }
    if (this.lang === 'az' && !this.userDataDir) {
      fs.mkdirSync(path.join(this.profile, 'Default'), { recursive: true });
      fs.writeFileSync(path.join(this.profile, 'Default', 'Preferences'), JSON.stringify({
        intl: { selected_languages: 'az,en-US,en', accept_languages: 'az,en-US,en' },
      }));
    }
    const ui = this.lang && this.lang !== 'az' ? this.lang : 'en';
    this.browser = await this.puppeteer.launch({
      executablePath: this.chrome,
      headless: !this.headful,
      pipe: true,
      // Only a flag keeps an unpacked extension installed across a restart, and
      // branded Chrome ignores it (since 137); the pipe works everywhere else.
      ...(this.loadByFlag
        ? { enableExtensions: true, ignoreDefaultArgs: ['--disable-extensions'] }
        : { enableExtensions: [this.extensionDir] }),
      userDataDir: this.profile,
      env: { ...process.env, FOCUSGUARD_BROWSER_SOCKET: socket },
      defaultViewport: null,
      args: ['--no-first-run', '--no-default-browser-check', '--window-size=1280,800',
        '--disable-quic', '--ignore-certificate-errors', '--disable-features=HttpsUpgrades,HttpsFirstBalancedModeAutoEnable',
        `--host-resolver-rules=MAP * 127.0.0.1:${this.web.port}`,
        ...(this.netlog ? [`--log-net-log=${this.netlog}`, '--net-log-capture-mode=Default'] : []),
        ...(this.loadByFlag ? [`--load-extension=${this.extensionDir}`] : []),
        `--lang=${ui}`, ...(ui === 'en' ? [] : ['-AppleLanguages', `(${ui})`]), ...this.extraArgs],
    });
    return this;
  }

  // Site access, on the extension as it ships. The host part goes through
  // chrome://extensions, as a person can. Then `permissions.request` needs no
  // prompt (a prompt is the one thing automation can't press), and the real
  // `permissions.onAdded` runs. `grant` is what asks; a page's own button can.
  async allowHosts() {
    const page = await this.browser.newPage();
    await page.goto('chrome://extensions');
    await page.evaluate((id) => chrome.developerPrivate.addHostPermission(id, '<all_urls>'), EXTENSION_ID);
    await page.close();
  }

  async grantSiteAccess() {
    await this.allowHosts();
    const ctl = await this.control();
    const granted = await ctl.evaluate(() => chrome.permissions.request({ permissions: ['scripting'], origins: ['<all_urls>'] }));
    if (!granted) throw new Error('site access was refused');
  }

  // The worker, once it's up.
  async worker(timeout = 15000) {
    const target = await this.browser.waitForTarget((t) => t.type() === 'service_worker' && t.url().startsWith(ORIGIN), { timeout });
    return target.worker();
  }

  // Evaluates in the worker: the extension's own view of tabs and rules.
  async sw(fn, ...args) {
    const worker = await this.worker();
    return worker.evaluate(fn, ...args);
  }

  // A plain extension page to ask chrome.* from without waking anything up:
  // the worker can be dead while this runs.
  async control() {
    if (this.ctl && !this.ctl.isClosed()) return this.ctl;
    this.ctl = await this.browser.newPage();
    await this.ctl.goto(`${ORIGIN}/_locales/en/messages.json`);
    return this.ctl;
  }

  async rules() {
    const ctl = await this.control();
    return ctl.evaluate(() => chrome.declarativeNetRequest.getSessionRules());
  }

  async killWorker() {
    const target = this.browser.targets().find((t) => t.type() === 'service_worker' && t.url().startsWith(ORIGIN));
    if (!target) return false;
    const worker = await target.worker();
    await worker.close();
    await until('the worker to stop', () => !this.browser.targets().some((t) => t.type() === 'service_worker' && t.url().startsWith(ORIGIN)), 10000);
    // Its helper goes with it, and the app notices.
    await until('the helper to go', () => !this.app?.server || this.app.greeted.size === 0, 5000);
    return true;
  }

  async closeWelcome() {
    const target = await this.browser.waitForTarget((t) => t.url().endsWith('pages/welcome.html'), { timeout: 10000 }).catch(() => null);
    if (target) await (await target.asPage()).close().catch(() => {});
  }

  // A new tab at `url`, in front.
  async tab(url, opts = {}) {
    const page = await this.browser.newPage();
    if (url) await page.goto(url, { waitUntil: 'load', ...opts }).catch(() => {});
    return page;
  }

  // The extension's connection, once it has one: waits for the app's hello.
  async connected() {
    await until('the extension to greet the app', () => this.app.greeted.size > 0, 15000);
    await sleep(150);
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    await this.browser.close().catch(() => {});
    if (!this.userDataDir) fs.rmSync(this.profile, { recursive: true, force: true });
  }
}

export function tempDir() {
  // Unix socket paths are short, so this stays in the short /tmp, not $TMPDIR.
  return fs.mkdtempSync(path.join(os.platform() === 'darwin' ? '/tmp' : os.tmpdir(), 'fg-e2e-'));
}
