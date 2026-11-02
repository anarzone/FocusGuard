// Every word the extension shows goes through t(). Normally that's
// _locales/<language>/messages.json through chrome.i18n, which picks the
// browser's UI language and falls back to English. Chrome has no Azerbaijani
// UI, so it can never pick az: that catalog is i18n/az.json, in the same
// format, and it's used when Azerbaijani is the top language in the browser's
// settings. The tests stub chrome.i18n (test/chrome-i18n.mjs).

let azerbaijani = null;   // the az catalog, while it's the one in use

// Picks the language, and loads the catalog if it takes one. Await it before
// the first t(). It never fails: without the catalog, chrome.i18n's language
// is used.
export async function loadLanguage() {
  try {
    const [top] = await chrome.i18n.getAcceptLanguages();
    if (!/^az([-_]|$)/i.test(top)) {
      azerbaijani = null;
    } else if (!azerbaijani) {
      const response = await fetch(chrome.runtime.getURL('i18n/az.json'));
      azerbaijani = response.ok ? await response.json() : null;
    }
  } catch {
    azerbaijani = null;
  }
}

// What chrome.i18n does to a message: $name$ becomes the placeholder's $1, then
// $1 becomes its value and $$ a dollar. Values aren't read again.
function fill({ message, placeholders }, values) {
  return message
    .replace(/\$(\w+)\$/g, (whole, name) => placeholders?.[name.toLowerCase()]?.content ?? whole)
    .replace(/\$(\$|[1-9])/g, (_, what) => (what === '$' ? '$' : values[Number(what) - 1] ?? ''));
}

// The message with `values` in its placeholders, in the catalog's $1, $2 order.
export function t(key, ...values) {
  const strings = values.map(String);
  const entry = azerbaijani?.[key];
  return entry ? fill(entry, strings) : chrome.i18n.getMessage(key, strings);
}

// The language the text is actually in. A browser in French reads the English
// catalog, so it needs English plural rules and <html lang="en">.
export function textLanguage() {
  return t('localeCode');
}

// For dates and times: the browser's language, region included, or Azerbaijani
// when the text is.
export function uiLanguage() {
  return azerbaijani ? textLanguage() : chrome.i18n.getUILanguage();
}

// For <html lang>: the browser's language if the text is in it, else the text's.
export function pageLanguage() {
  const ui = uiLanguage();
  const text = textLanguage();
  return ui.split(/[-_]/)[0].toLowerCase() === text ? ui : text;
}

function counted(rules, base, count, values) {
  return t(`${base}_${rules.select(count)}`, count, ...values) || t(`${base}_other`, count, ...values);
}

// `base_one` or `base_other` by the language's rules, with `count` as the
// first placeholder. A category the catalog doesn't have falls back to `_other`.
export function plural(base, count, ...values) {
  return counted(new Intl.PluralRules(textLanguage()), base, count, values);
}

// The same for ordinals: `base_one` (1st), `base_two` (2nd), `base_few` (3rd),
// `base_other` (4th).
export function ordinal(base, count, ...values) {
  return counted(new Intl.PluralRules(textLanguage(), { type: 'ordinal' }), base, count, values);
}
