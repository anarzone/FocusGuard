// chrome.i18n for Node, reading the real catalogs the way Chromium does:
// $name$ becomes the placeholder's content, then $1…$9 become the values and
// $$ a dollar. Importing this sets English; useLocale switches.

import { readFileSync } from 'node:fs';

export function catalog(language) {
  return JSON.parse(readFileSync(new URL(`../_locales/${language}/messages.json`, import.meta.url)));
}

// `language` is the catalog read; `ui` is what the browser says it runs in.
export function useLocale(language, ui = language) {
  const messages = catalog(language);
  globalThis.chrome = {
    i18n: {
      getUILanguage: () => ui,
      getMessage(key, values = []) {
        const entry = messages[key];
        if (!entry) return '';
        return entry.message
          .replace(/\$(\w+)\$/g, (_, name) => entry.placeholders[name.toLowerCase()].content)
          .replace(/\$(\$|\d)/g, (_, what) => (what === '$' ? '$' : values[Number(what) - 1] ?? ''));
      },
    },
  };
}

useLocale('en', 'en-US');
