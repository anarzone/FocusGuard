// chrome.i18n for Node, reading the real catalogs the way Chromium does:
// $name$ becomes the placeholder's content, then $1…$9 become the values and
// $$ a dollar. Importing this sets up an English browser; useBrowser and
// useLocale switch.

import { existsSync, readFileSync } from 'node:fs';
import { loadLanguage } from '../src/lib/i18n.js';

const file = (path) => new URL(`../${path}`, import.meta.url);
const CATALOG_PATHS = { az: 'i18n/az.json' };

export function catalog(language) {
  return JSON.parse(readFileSync(file(CATALOG_PATHS[language] || `_locales/${language}/messages.json`)));
}

export function chromiumMessage(entry, values = []) {
  return entry.message
    .replace(/\$(\w+)\$/g, (_, name) => entry.placeholders[name.toLowerCase()].content)
    .replace(/\$(\$|\d)/g, (_, what) => (what === '$' ? '$' : values[Number(what) - 1] ?? ''));
}

// A browser: `ui` picks its _locales catalog, or English if there isn't one, and
// `accept` is the languages in its settings. `load` stands in for fetching a
// file; by default it finds i18n/az.json.
export async function useBrowser({ ui = 'en-US', accept = [ui], load } = {}) {
  const language = ui.split(/[-_]/)[0];
  const messages = catalog(existsSync(file(`_locales/${language}/messages.json`)) ? language : 'en');
  globalThis.chrome = {
    runtime: { getURL: (path) => `chrome-extension://test/${path}` },
    i18n: {
      getUILanguage: () => ui,
      getAcceptLanguages: async () => accept,
      getMessage: (key, values = []) => (messages[key] ? chromiumMessage(messages[key], values) : ''),
    },
  };
  globalThis.fetch = load || (async () => ({ ok: true, json: async () => catalog('az') }));
  await loadLanguage();
}

// Someone reading `language`, whichever way the browser gets there. For the
// languages in _locales, `ui` can differ from what the browser says it runs in.
export function useLocale(language, ui = language) {
  return language === 'az' ? useBrowser({ accept: ['az', 'en-US', 'en'] }) : useBrowser({ ui });
}

await useLocale('en', 'en-US');
