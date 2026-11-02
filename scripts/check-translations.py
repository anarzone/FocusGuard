#!/usr/bin/env python3
"""Fails when a translation is missing or would break at runtime.

Run by CI after the build. For every key in the string catalogs (and every
string on the paused-tab page), German and Azerbaijani must be filled in with
the same format specifiers and tokens as the English.

With --built it also fails on strings in the code that no catalog has yet:
those show in English, and a build outside Xcode never adds them by itself.
Add them by building in Xcode, or with `xcrun xcstringstool sync`, then
translate them (README.md, "Languages").
"""
import glob
import json
import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGUAGES = ("de", "az")
CATALOGS = (
    "FocusGuard/Resources/Localizable.xcstrings",
    "FocusGuard/Resources/InfoPlist.xcstrings",
    "FocusGuard/Resources/AppShortcuts.xcstrings",
    "FocusGuardWidgets/Localizable.xcstrings",
)
PAGE = "FocusGuard/Resources/paused.html"

SPECIFIER = re.compile(r"%(?:(\d+)\$)?(#@\w+@|lld|ld|d|@|lf|f|%)")
TOKEN = re.compile(r"\$\{\w+\}|\{end\}")

problems = []


def specifiers(text):
    """(position, kind) pairs, positions resolved; a plural slot counts as lld."""
    found, next_position = [], 1
    for match in SPECIFIER.finditer(text):
        position, kind = match.group(1), match.group(2)
        if kind == "%":
            continue
        if position is None:
            position, next_position = next_position, next_position + 1
        found.append((int(position), "lld" if kind.startswith("#@") else kind))
    return sorted(found)


def forms(localization):
    """Every text a localization can show: {name: text}."""
    if "stringUnit" in localization:
        out = {"": localization["stringUnit"].get("value", "")}
    else:
        plural = localization.get("variations", {}).get("plural", {})
        out = {name: form.get("stringUnit", {}).get("value", "") for name, form in plural.items()}
    return out


def check_entry(catalog, key, entry):
    source = key
    english = entry.get("localizations", {}).get("en")
    if english and forms(english).get("other", forms(english).get("")):
        source = forms(english).get("other", forms(english).get(""))
    is_id = "%" not in key and "%" in source
    wanted = specifiers(source)

    for language in LANGUAGES:
        localization = entry.get("localizations", {}).get(language)
        if not localization:
            problems.append(f"{catalog}: {key!r} has no {language} translation")
            continue
        texts = forms(localization)
        if not texts or not all(text.strip() or not key.strip() for text in texts.values()):
            problems.append(f"{catalog}: {key!r} has an empty {language} translation")
            continue
        if "variations" in localization and "other" not in texts:
            problems.append(f"{catalog}: {key!r} has no {language} 'other' plural form")
        for name, text in texts.items():
            # A singular may spell out its number: "A minute".
            if name != "one" and specifiers(text) != wanted:
                problems.append(f"{catalog}: {key!r} {language} has {text!r}: different format specifiers")
            if sorted(TOKEN.findall(text)) != sorted(TOKEN.findall(source)):
                problems.append(f"{catalog}: {key!r} {language} has {text!r}: different tokens")
            if not is_id and source.count("|") != text.count("|"):
                problems.append(f"{catalog}: {key!r} {language} has {text!r}: keep the one | mark")
        for slot in localization.get("substitutions", {}).values():
            plural = slot.get("variations", {}).get("plural", {})
            if "other" not in plural:
                problems.append(f"{catalog}: {key!r} {language} has a plural slot with no 'other' form")


def check_catalogs():
    catalogs = {}
    for path in CATALOGS:
        with open(os.path.join(ROOT, path), encoding="utf8") as file:
            catalog = json.load(file)
        catalogs[path] = catalog["strings"]
        for key, entry in catalog["strings"].items():
            if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
                continue
            check_entry(path, key, entry)
    return catalogs


def check_permission_prompts(catalogs):
    """The English prompts live in project.yml, and the catalog repeats them."""
    with open(os.path.join(ROOT, "FocusGuard/Resources/Info.plist"), "rb") as file:
        info = plistlib.load(file)
    strings = catalogs["FocusGuard/Resources/InfoPlist.xcstrings"]
    for key, text in info.items():
        if not key.endswith("UsageDescription"):
            continue
        if key not in strings:
            problems.append(f"InfoPlist.xcstrings: {key} is missing")
        elif strings[key]["localizations"]["en"]["stringUnit"]["value"] != text:
            problems.append(f"InfoPlist.xcstrings: English {key} differs from project.yml")


def check_page():
    """paused.html: a table per language inside STRINGS, with {named} values."""
    with open(os.path.join(ROOT, PAGE), encoding="utf8") as file:
        html = file.read()
    tables = {}
    for language, body in re.findall(r"^    (\w\w): \{\n(.*?)^    \}", html, re.S | re.M):
        tables[language] = dict(re.findall(r'^\s+(\w+): "(.*)",?$', body, re.M))
    english = tables.get("en", {})
    if not english:
        problems.append(f"{PAGE}: couldn't find STRINGS")
    for language in LANGUAGES:
        table = tables.get(language, {})
        for key, text in english.items():
            if key not in table:
                problems.append(f"{PAGE}: {key} has no {language} translation")
            elif sorted(re.findall(r"\{\w+\}", table[key])) != sorted(re.findall(r"\{\w+\}", text)):
                problems.append(f"{PAGE}: {key} {language} has different {{values}}")


def check_built(catalogs):
    """Every string the compiler found in the code is in its target's catalog."""
    roots = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/FocusGuard-*/Build/Intermediates.noindex"))
    roots += glob.glob(os.path.join(ROOT, "build/*/Build/Intermediates.noindex"))
    targets = {
        "FocusGuard.build": ("FocusGuard/Resources/Localizable.xcstrings", "FocusGuard/Resources/AppShortcuts.xcstrings"),
        "FocusGuardWidgets.build": ("FocusGuardWidgets/Localizable.xcstrings",),
    }
    seen = 0
    for target, (catalog, *others) in targets.items():
        known = set(catalogs[catalog]).union(*(catalogs[other] for other in others))
        for root in roots:
            for data in glob.glob(f"{root}/FocusGuard.build/*/{target}/Objects-normal/*/*.stringsdata"):
                seen += 1
                with open(data, encoding="utf8") as file:
                    for table in json.load(file).get("tables", {}).values():
                        for item in table:
                            if item["key"] not in known:
                                problems.append(f"{catalog}: {item['key']!r} is in the code but not in the catalog")
    if not seen:
        problems.append("--built: found no .stringsdata; build first")


def main():
    catalogs = check_catalogs()
    check_permission_prompts(catalogs)
    check_page()
    if "--built" in sys.argv:
        check_built(catalogs)
    if problems:
        print("\n".join(sorted(set(problems))))
        print(f"\n{len(set(problems))} translation problems")
        return 1
    print("Translations are complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
