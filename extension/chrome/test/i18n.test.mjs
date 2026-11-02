import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { catalog, chromiumMessage, useBrowser, useLocale } from './chrome-i18n.mjs';
import { dayAndMonth, lastSeen, listSummary, minutesLabel, minutesPhrase } from '../src/lib/format.js';
import { loadLanguage, ordinal, pageLanguage, plural, t, textLanguage, uiLanguage } from '../src/lib/i18n.js';
import { presetName, toolbar } from '../src/lib/view.js';
import { Conn } from '../src/lib/protocol.js';

const ROOT = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, ROOT), 'utf8');
const en = catalog('en');
const TRANSLATIONS = { de: catalog('de'), az: catalog('az') };
const fixture = JSON.parse(read('test/fixtures/state-focusing.json'));

afterEach(() => useLocale('en', 'en-US'));

const used = (entry) => new Set([...entry.message.matchAll(/\$(\w+)\$/g)].map((m) => m[1].toLowerCase()));
const declared = (entry) => Object.keys(entry.placeholders || {}).map((name) => name.toLowerCase());
const countKey = /_(one|two|few|other)$/;

// --- The catalogs ------------------------------------------------------------

test('every catalog is known here, so a new one gets these checks', () => {
  assert.deepEqual(readdirSync(new URL('_locales/', ROOT)).sort(), ['de', 'en']);
  assert.deepEqual(readdirSync(new URL('i18n/', ROOT)), ['az.json']);
});

for (const [language, messages] of Object.entries(TRANSLATIONS)) {
  test(`${language}: the same keys as English, none missing, none extra`, () => {
    const keys = Object.keys(messages);
    assert.deepEqual(Object.keys(en).filter((key) => !keys.includes(key)), [], 'missing');
    assert.deepEqual(keys.filter((key) => !en[key]), [], 'extra');
  });

  test(`${language}: the same placeholders as English, numbered the same`, () => {
    for (const [key, entry] of Object.entries(en)) {
      const contents = (e) => Object.entries(e.placeholders || {}).map(([name, p]) => [name, p.content]).sort();
      assert.deepEqual(contents(messages[key]), contents(entry), key);
    }
  });
}

test('every message is valid for Chromium', () => {
  for (const [language, messages] of Object.entries({ en, ...TRANSLATIONS })) {
    const lower = new Set();
    for (const [key, entry] of Object.entries(messages)) {
      const where = `${language}/${key}`;
      // Chromium refuses to load a catalog that breaks either of these.
      assert.match(key, /^[A-Za-z0-9_]+$/, where);
      assert.ok(!lower.has(key.toLowerCase()), `${where}: keys ignore case, and this one repeats`);
      lower.add(key.toLowerCase());
      assert.ok(entry.message.length > 0, `${where} is empty`);
      for (const name of used(entry)) assert.ok(declared(entry).includes(name), `${where} uses $${name}$ but doesn't declare it`);
      // A declared value has to show, except a count the sentence doesn't need to say.
      for (const name of declared(entry)) {
        if (!(name === 'count' && countKey.test(key))) assert.ok(used(entry).has(name), `${where} never uses $${name}$`);
      }
    }
  }
});

test('localeCode names its own folder', () => {
  assert.equal(en.localeCode.message, 'en');
  for (const [language, messages] of Object.entries(TRANSLATIONS)) assert.equal(messages.localeCode.message, language);
});

test('counted messages have at least _one and _other, and start with the count', () => {
  for (const key of Object.keys(en).filter((k) => countKey.test(k))) {
    const base = key.replace(countKey, '');
    assert.ok(en[`${base}_other`], `${base}_other`);
    assert.ok(en[`${base}_one`], `${base}_one`);
    assert.equal(en[key].placeholders.count.content, '$1', key);
  }
});

test('Azerbaijani puts no suffix directly on a number or a value', () => {
  for (const [key, { message }] of Object.entries(TRANSLATIONS.az)) {
    assert.doesNotMatch(message, /\$[a-z]+\$['’-]?[a-zəıöüğşç]/i, key);
    assert.doesNotMatch(message, /\d['’-][a-zəıöüğşç]/i, key);
  }
});

test('German says du, never Sie', () => {
  for (const [key, { message }] of Object.entries(TRANSLATIONS.de)) {
    assert.doesNotMatch(message, /\b(Sie|Ihr|Ihre|Ihren|Ihrem|Ihrer|Ihnen)\b/, key);
  }
});

// --- The manifest ------------------------------------------------------------

test('the manifest names English as the default, and its messages resolve', () => {
  const manifest = JSON.parse(read('manifest.json'));
  assert.equal(manifest.default_locale, 'en');
  assert.equal(manifest.name, 'FocusGuard');
  assert.equal(manifest.short_name, 'FocusGuard');
  assert.equal(manifest.description, '__MSG_extDescription__');
  assert.equal(manifest.action.default_title, '__MSG_extActionTitle__');
  for (const [, key] of read('manifest.json').matchAll(/__MSG_(\w+)__/g)) assert.ok(en[key], key);
});

test('the manifest leaves the Azerbaijani catalog private to the extension', () => {
  const manifest = JSON.parse(read('manifest.json'));
  const exposed = manifest.web_accessible_resources.flatMap((entry) => entry.resources);
  assert.ok(!exposed.some((path) => path.startsWith('i18n') || path === '*'));
});

test('the description fits the 132 characters the store allows', () => {
  for (const [language, messages] of Object.entries({ en, ...TRANSLATIONS })) {
    assert.ok(messages.extDescription.message.length <= 132, language);
  }
});

// --- The code ----------------------------------------------------------------

const SOURCES = [
  'src/background.js',
  ...readdirSync(new URL('src/lib/', ROOT)).map((file) => `src/lib/${file}`),
  ...readdirSync(new URL('pages/', ROOT)).filter((file) => file.endsWith('.js')).map((file) => `pages/${file}`),
];
const PAGES = readdirSync(new URL('pages/', ROOT)).filter((file) => file.endsWith('.html')).map((file) => `pages/${file}`);

// The text of a call's arguments, from just after its "(": top-level pieces.
function argumentsOf(source, start) {
  const pieces = [''];
  const closers = [];
  for (let i = start; i < source.length; i++) {
    const c = source[i];
    const top = closers[closers.length - 1];
    if (top === "'" || top === '"' || top === '`') {
      if (c === '\\') { pieces[pieces.length - 1] += c + source[++i]; continue; }
      if (c === top) closers.pop();
      else if (top === '`' && c === '$' && source[i + 1] === '{') { closers.push('}'); pieces[pieces.length - 1] += source[i++]; }
    } else if (c === "'" || c === '"' || c === '`') closers.push(c);
    else if (c === '(') closers.push(')');
    else if (c === '[') closers.push(']');
    else if (c === '{') closers.push('}');
    else if (c === top) closers.pop();
    else if (c === ')' && !closers.length) return pieces.map((piece) => piece.trim()).filter(Boolean);
    else if (c === ',' && !closers.length) { pieces.push(''); continue; }
    pieces[pieces.length - 1] += c;
  }
  throw new Error('unclosed call');
}

// Every call that names a message: t('key', …), plural('base', n, …),
// ordinal('base', n, …), chrome.i18n.getMessage('key', […]).
function messageCalls() {
  const calls = [];
  const pattern = /(?<![\w.$])(t|plural|ordinal)\(|chrome\.i18n\.getMessage\(/g;
  for (const path of SOURCES) {
    if (path === 'src/lib/i18n.js') continue; // where they're defined
    const source = read(path);
    for (const match of source.matchAll(pattern)) {
      const args = argumentsOf(source, match.index + match[0].length);
      calls.push({ path, kind: match[1] || 'getMessage', args });
    }
  }
  return calls;
}

test('every message the code asks for exists, with the right number of values', () => {
  const calls = messageCalls();
  assert.ok(calls.length > 300, `only found ${calls.length} calls`);
  for (const { path, kind, args } of calls) {
    // localizePage reads keys from the HTML, checked below.
    if (path === 'src/lib/dom.js' && !/^'/.test(args[0])) continue;
    const key = /^'(\w+)'$/.exec(args[0])?.[1];
    assert.ok(key, `${path}: ${kind}(${args[0]}…) has to name its key, so this test can see it`);
    if (kind === 't' || kind === 'getMessage') {
      assert.ok(en[key], `${path}: no message ${key}`);
      // A spread stands for several values; the catalog's own test covers the rest.
      if (args.some((arg) => arg.startsWith('...'))) continue;
      const count = kind === 't' ? args.length - 1 : (args[1] ? argumentsOf(`${args[1].slice(1, -1)})`, 0).length : 0);
      assert.equal(count, declared(en[key]).length, `${path}: ${key} takes ${declared(en[key]).length} values`);
    } else {
      assert.ok(en[`${key}_other`], `${path}: no message ${key}_other`);
      assert.equal(args.length - 1, declared(en[`${key}_other`]).length, `${path}: ${key} takes ${declared(en[`${key}_other`]).length} values`);
    }
  }
});

test('each page picks its language before it says anything', () => {
  for (const path of PAGES.map((page) => page.replace(/\.html$/, '.js'))) {
    const source = read(path);
    const first = source.search(/(?<![\w.$])(t|plural|ordinal)\(/);
    const load = source.indexOf('await localizePage();');
    assert.ok(load >= 0 && load < first, `${path} has to await localizePage() before its first message`);
  }
  const worker = read('src/background.js');
  const load = worker.indexOf('await loadLanguage();');
  assert.ok(load >= 0 && load < worker.indexOf('updateToolbar();'), 'the worker has to load the language before it draws the toolbar');
});

test('the HTML shows nothing but the name before the language is known', () => {
  for (const path of PAGES) assert.match(read(path), /<title[^>]*>FocusGuard<\/title>/, path);
});

test('every data-i18n key in the HTML exists', () => {
  let found = 0;
  for (const path of PAGES) {
    for (const [, key] of read(path).matchAll(/data-i18n(?:-[a-z-]+)?="([^"]+)"/g)) {
      found += 1;
      assert.ok(en[key], `${path}: no message ${key}`);
    }
  }
  assert.ok(found > 0);
});

test('no message goes unused', () => {
  const wanted = new Set(['localeCode']);
  for (const { kind, args } of messageCalls()) {
    const key = /^'(\w+)'$/.exec(args[0])?.[1];
    if (!key) continue;
    if (kind === 't' || kind === 'getMessage') wanted.add(key);
    else for (const known of Object.keys(en)) if (known.replace(countKey, '') === key) wanted.add(known);
  }
  for (const [, key] of read('manifest.json').matchAll(/__MSG_(\w+)__/g)) wanted.add(key);
  for (const path of PAGES) for (const [, key] of read(path).matchAll(/data-i18n(?:-[a-z-]+)?="([^"]+)"/g)) wanted.add(key);
  assert.deepEqual(Object.keys(en).filter((key) => !wanted.has(key)), []);
});

// --- Behaviour in each language ---------------------------------------------

test('compact durations', async () => {
  const samples = { en: ['24m', '2h', '1h 5m'], de: ['24 Min', '2 Std.', '1 Std. 5 Min'], az: ['24 dəq', '2 saat', '1 saat 5 dəq'] };
  for (const [language, expected] of Object.entries(samples)) {
    await useLocale(language);
    assert.deepEqual([minutesLabel(24 * 60), minutesLabel(7200), minutesLabel(3900)], expected, language);
  }
});

test('plurals follow the language: Azerbaijani nouns stay singular after numbers', async () => {
  assert.deepEqual([minutesPhrase(60), minutesPhrase(120)], ['1 minute', '2 minutes']);
  await useLocale('de');
  assert.deepEqual([minutesPhrase(60), minutesPhrase(120)], ['1 Minute', '2 Minuten']);
  await useLocale('az');
  assert.deepEqual([minutesPhrase(60), minutesPhrase(120)], ['1 dəqiqə', '2 dəqiqə']);
});

test('plurals use the rules of the text, not of the browser', async () => {
  // A Russian browser reads the English catalog. Russian calls 21 "one".
  await useLocale('en', 'ru');
  assert.equal(textLanguage(), 'en');
  assert.equal(plural('minutesPhrase', 21), '21 minutes');
});

test('a plural category the catalog lacks falls back to _other', async () => {
  const real = Intl.PluralRules;
  globalThis.Intl.PluralRules = class { select() { return 'many'; } };
  try {
    assert.equal(plural('minutesPhrase', 5), '5 minutes');
  } finally {
    globalThis.Intl.PluralRules = real;
  }
});

test('ordinals: English suffixes, German dots, Azerbaijani without a suffix', async () => {
  const visits = [1, 2, 3, 4, 11, 21, 22, 23].map((n) => ordinal('blockFooterNth', n));
  assert.deepEqual(visits.map((text) => text.split(' ')[0]), ['1st', '2nd', '3rd', '4th', '11th', '21st', '22nd', '23rd']);
  await useLocale('de');
  assert.equal(ordinal('blockFooterNth', 4), 'zum 4. Mal in dieser Session');
  await useLocale('az');
  assert.equal(ordinal('blockFooterNth', 4), 'bu sessiyada 4 dəfə');
  assert.equal(ordinal('blockFooterNth', 6), 'bu sessiyada 6 dəfə');
});

test('list summaries', async () => {
  const six = ['x.com', 'reddit.com', 'a.com', 'b.com', 'c.com', 'd.com'];
  await useLocale('de');
  assert.equal(listSummary(['x.com', 'reddit.com']), 'x.com und reddit.com');
  assert.equal(listSummary(six), 'x.com, reddit.com und 4 weitere');
  await useLocale('az');
  assert.equal(listSummary(['x.com', 'reddit.com']), 'x.com və reddit.com');
  assert.equal(listSummary(six), 'x.com, reddit.com və daha 4 sayt');
});

test('preset names come from the stable value the app sends', async () => {
  await useLocale('de');
  assert.deepEqual(['gentle', 'standard', 'strict', undefined].map(presetName), ['Sanft', 'Standard', 'Streng', 'Standard']);
  await useLocale('az');
  assert.deepEqual(['gentle', 'standard', 'strict', undefined].map(presetName), ['Yumşaq', 'Standart', 'Sərt', 'Standart']);
});

test('last connected: a whole sentence, with the date in the browser language', async () => {
  const now = new Date(2026, 9, 23, 12, 0).getTime();
  const today = new Date(2026, 9, 23, 10, 5).getTime();
  const yesterday = new Date(2026, 9, 22, 18, 5).getTime();
  const earlier = new Date(2026, 9, 21, 18, 5).getTime();
  assert.equal(lastSeen(null, now), null);

  await useLocale('en', 'en-GB');
  assert.equal(lastSeen(today, now), 'Last connected today at 10:05');
  assert.equal(lastSeen(earlier, now), 'Last connected on 21 Oct');

  await useLocale('de');
  assert.equal(lastSeen(yesterday, now), 'Zuletzt verbunden: gestern um 18:05 Uhr');
  assert.equal(lastSeen(earlier, now), 'Zuletzt verbunden am 21. Okt.');

  await useLocale('az');
  assert.equal(lastSeen(today, now), 'Son qoşulma: bu gün, saat 10:05');
});

test("a date in a language Chromium's Intl has no months for comes out as digits", async () => {
  const real = Date.prototype.toLocaleDateString;
  Date.prototype.toLocaleDateString = () => 'M10 21';
  try {
    assert.equal(dayAndMonth(new Date(2026, 9, 21).getTime()), '21.10');
    assert.equal(dayAndMonth(new Date(2026, 2, 5).getTime()), '5.03');
  } finally {
    Date.prototype.toLocaleDateString = real;
  }
});

test('the toolbar tooltip in each language', async () => {
  const asOf = fixture.session.asOf;
  const title = () => toolbar({ conn: Conn.connected, state: fixture, now: asOf, activeHost: 'news.ycombinator.com' }).title;
  const off = () => toolbar({ conn: Conn.notRunning, state: null }).title;
  await useLocale('de');
  assert.equal(title(), 'FocusGuard · noch 23 Min · 6 Websites blockiert');
  assert.equal(off(), 'FocusGuard läuft nicht');
  await useLocale('az');
  assert.equal(title(), 'FocusGuard · 23 dəq qalıb · 6 sayt bloklanıb');
  assert.equal(off(), 'FocusGuard işləmir');
});

test('values land in the right place when a language reorders them', async () => {
  await useLocale('az');
  // English puts the session's name first; so does the catalog's numbering.
  assert.equal(t('popupRuleWait', 'Standart', 5, '2 dəqiqə'),
    'Bu səhifələr açılmır. Standart rejim 5 saniyə gözlədikdən sonra 2 dəqiqə müddətinə keçid verir.');
  assert.equal(t('limitMinutesTitle', 30, 'reddit.com'), 'reddit.com üçün bugünkü 30 dəqiqəniz bitdi.');
  assert.equal(t('blockRingPlanned', 27, 50, 2, '23:00'),
    'Sessiya dairəsi: 50 dəqiqənin 27 dəqiqəsi keçib, bunun 2 dəqiqəsi yayınmadır. 23:00 qalıb.');
});

// --- Which language, and how it's loaded --------------------------------------

const az = catalog('az');
const de = catalog('de');

test('Azerbaijani on top of the browser settings picks the az catalog', async () => {
  for (const top of ['az', 'az-AZ', 'az_AZ', 'AZ', 'az-Latn-AZ']) {
    await useBrowser({ accept: [top, 'en-US', 'en'] });
    assert.equal(t('popupHide'), az.popupHide.message, top);
    assert.equal(textLanguage(), 'az', top);
    await useLocale('en', 'en-US');
  }
});

test('Azerbaijani wins over a browser UI in another language', async () => {
  await useBrowser({ ui: 'de', accept: ['az', 'de-DE', 'de'] });
  assert.equal(t('popupHide'), az.popupHide.message);
});

test('only the top language counts, and only az itself', async () => {
  const cases = [['en-US', 'az'], ['de-DE', 'az', 'en'], ['azb'], ['azb-IR', 'az'], []];
  for (const accept of cases) {
    let fetched = false;
    await useBrowser({ accept, load: async () => { fetched = true; return { ok: true, json: async () => az }; } });
    assert.equal(textLanguage(), 'en', String(accept));
    assert.equal(fetched, false, String(accept));
  }
});

test('English and German stay with chrome.i18n, and fetch nothing', async () => {
  const load = async () => { throw new Error('nothing should be fetched'); };
  await useBrowser({ ui: 'de', accept: ['de-DE', 'de', 'en-US', 'en'], load });
  assert.equal(t('popupHide'), de.popupHide.message);
  assert.equal(t('blockWaitTitleUntil', 'x.com', '21:40'), 'x.com kann bis 21:40 Uhr warten.');
  assert.equal(uiLanguage(), 'de');
  assert.equal(pageLanguage(), 'de');
  assert.equal(plural('minutesPhrase', 2), '2 Minuten');

  await useBrowser({ ui: 'en-GB', accept: ['en-GB', 'en'], load });
  assert.equal(t('popupHide'), 'Hide');
  assert.equal(uiLanguage(), 'en-GB');
  assert.equal(pageLanguage(), 'en-GB');
});

test('az sets the page language, dates and plurals, whatever the browser UI is', async () => {
  await useBrowser({ ui: 'en-US', accept: ['az', 'en-US'] });
  assert.equal(pageLanguage(), 'az');
  assert.equal(uiLanguage(), 'az');
  assert.equal(plural('minutesPhrase', 1), '1 dəqiqə');
  assert.equal(plural('minutesPhrase', 21), '21 dəqiqə');
  assert.equal(ordinal('blockFooterNth', 3), 'bu sessiyada 3 dəfə');
  assert.equal(minutesLabel(3900), '1 saat 5 dəq');
});

test('the page language for a browser the text is not in', async () => {
  await useBrowser({ ui: 'fr-FR', accept: ['fr-FR', 'fr'] });
  assert.equal(pageLanguage(), 'en');
  await useBrowser({ ui: 'de-AT', accept: ['de-AT', 'de'] });
  assert.equal(pageLanguage(), 'de-AT');
});

test('the catalog is read from the extension, once', async () => {
  const urls = [];
  const load = async (url) => { urls.push(url); return { ok: true, json: async () => az }; };
  await useBrowser({ accept: ['az'], load });
  await loadLanguage();
  await loadLanguage();
  assert.deepEqual(urls, ['chrome-extension://test/i18n/az.json']);
});

test('moving Azerbaijani off the top goes back to chrome.i18n without a reload', async () => {
  const languages = ['az', 'en-US'];
  await useBrowser({ accept: languages });
  assert.equal(textLanguage(), 'az');
  languages.reverse();
  await loadLanguage();
  assert.equal(textLanguage(), 'en');
  languages.reverse();
  await loadLanguage();
  assert.equal(textLanguage(), 'az');
});

const failures = {
  'a failed fetch': async () => { throw new TypeError('Failed to fetch'); },
  'a missing file': async () => ({ ok: false, json: async () => catalog('az') }),
  'a broken file': async () => ({ ok: true, json: async () => { throw new SyntaxError('Unexpected token'); } }),
};

for (const [name, load] of Object.entries(failures)) {
  test(`${name} falls back to the browser's own language`, async () => {
    await useBrowser({ accept: ['az', 'en-US'], load });
    assert.equal(t('popupHide'), 'Hide');
    assert.equal(textLanguage(), 'en');
    assert.equal(pageLanguage(), 'en-US');
    assert.equal(minutesPhrase(120), '2 minutes');

    await useBrowser({ ui: 'de', accept: ['az', 'de'], load });
    assert.equal(t('popupHide'), de.popupHide.message);
    assert.equal(pageLanguage(), 'de');
  });
}

test('browser settings that can\'t be read fall back too', async () => {
  await useBrowser({ ui: 'de' });
  chrome.i18n.getAcceptLanguages = async () => { throw new Error('no settings'); };
  await loadLanguage();
  assert.equal(t('popupHide'), de.popupHide.message);
});

test('settings that stop being readable drop a catalog already in use', async () => {
  await useBrowser({ accept: ['az'] });
  assert.equal(textLanguage(), 'az');
  chrome.i18n.getAcceptLanguages = async () => { throw new Error('no settings'); };
  await loadLanguage();
  assert.equal(textLanguage(), 'en');
});

test('a key the az catalog lacks comes from chrome.i18n, not blank', async () => {
  const { popupHide, ...rest } = az;
  await useBrowser({ accept: ['az'], load: async () => ({ ok: true, json: async () => rest }) });
  assert.equal(t('popupHide'), 'Hide');
  assert.equal(t('popupEndBreak'), az.popupEndBreak.message);
});

test('t reads the az catalog exactly as Chromium reads a messages.json', async () => {
  await useLocale('az');
  for (const [key, entry] of Object.entries(az)) {
    const values = declared(entry).map((_, i) => `v${i + 1}`);
    assert.equal(t(key, ...values), chromiumMessage(entry, values), key);
  }
});

test('values are taken as they are, dollars included', async () => {
  await useLocale('az');
  assert.equal(t('popupCategoryChange', '$1 and $$'), 'Kateqoriya: $1 and $$. Dəyişin');
  assert.equal(t('popupRuleNow', '$2', '$1'), 'Bu səhifələr açılmır. $2 rejim dərhal $1 müddətinə keçid verir.');
});
