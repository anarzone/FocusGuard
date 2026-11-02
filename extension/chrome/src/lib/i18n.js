// Every word the extension shows comes from _locales/<language>/messages.json
// through chrome.i18n, which picks the browser's UI language and falls back to
// English. The tests stub chrome.i18n (test/chrome-i18n.mjs).

// The message with `values` in its placeholders, in the catalog's $1, $2 order.
export function t(key, ...values) {
  return chrome.i18n.getMessage(key, values.map(String));
}

// The browser's language, region included: for dates and times.
export function uiLanguage() {
  return chrome.i18n.getUILanguage();
}

// The language the text is actually in. A browser in French reads the English
// catalog, so it needs English plural rules and <html lang="en">.
export function textLanguage() {
  return t('localeCode');
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
