# FocusGuard for Chrome, Arc, Brave and Edge

The browser half of FocusGuard. It's free to install and does nothing on its
own: it works with FocusGuard for Mac.

- **Free:** tells the app which page you're on (address and title), pauses a
  distracting tab when the Mac's block screen comes up, and lets you change a
  site's category from the popup. Pausing is the app's `TabPauser`
  (`FocusGuard/Extension/ExtensionTabPauser.swift`): where the extension is
  connected it does the pausing, with `tabs.update`, and the app falls back to
  AppleScript elsewhere. The extension's paused page takes the same fields
  and shows the same states as the app's `paused.html` (paused, reopens
  later, session over, daily limit), and its buttons call the same routes.
- **Pro** (only when the app says the user has Pro or a trial): keeps
  distracting sites and parts of sites from loading during sessions, sorts
  YouTube video by video, and shows the daily-limit page. Site access is asked
  for only when the user turns this on.

Plain JavaScript, Manifest V3, no build step and no dependencies.

## Try it

1. Build and run FocusGuard (or install it). On launch the app writes the
   native-messaging host manifest for every Chromium browser it finds (see
   `FocusGuard/Extension/NativeHostInstaller.swift`). The manifest points at the
   helper inside the running copy of the app, so the last copy you opened wins.
2. Open `chrome://extensions` (or `arc://`, `brave://`, `edge://`), turn on
   **Developer mode**, click **Load unpacked** and pick this folder,
   `extension/chrome`.
3. The welcome page opens. Pin the shield from the puzzle-piece menu.

The fixed `key` in `manifest.json` gives the unpacked extension the same ID
everywhere, `abeehapgjhkgbfokheomoahlgidgcoik`, which is the ID the app's host
manifest allows.

The Pro parts follow the app's plan (`Entitlements`): each one is unlocked
by its own feature (`blockInBrowser`, `partsOfSites`, `youtubePerVideo`,
`unlimitedLimits`). To try them in a debug build without a licence:

```bash
defaults write com.anar.focusguard plan.debugOverride pro
```

(`trial` or `trial:2` work too; delete the key to go back to the real plan.)
Then turn on site access from the popup or Options. Passes, the waits before
buttons unlock and extra time on limits come from the app's `OverridePolicy`
for the preset in force, sent with every state.

## How it talks to the app

```
popup / block page / options ──runtime messages──▶ background service worker
background ──chrome.runtime.connectNative("com.anar.focusguard")──▶
FocusGuard.app/Contents/Helpers/FocusGuardBrowserHelper ──Unix socket──▶ FocusGuard.app
```

- The helper is started by the browser, one per browser profile. It relays
  length-prefixed JSON both ways and, while the app is closed, answers for it
  (the popup shows "FocusGuard isn't running" and can open the app).
- The socket is `~/Library/Application Support/FocusGuard/browser.sock`, readable
  only by the user. Nothing goes over the network; there is no FocusGuard server.
- The messages are defined in `src/lib/protocol.js` and
  `FocusGuard/Extension/BrowserMessage.swift`. `test/fixtures/state-focusing.json`
  is checked by both the Swift and the JavaScript tests, so the two can't drift.
- While an extension is connected for a browser, the app uses its reports
  instead of AppleScript for that browser (no Automation prompt, titles without
  Screen Recording). With no extension connected it falls back to AppleScript.

## Files

| Path | What |
| --- | --- |
| `manifest.json` | MV3 manifest, with the development `key` |
| `src/background.js` | native connection, tab reports, pausing tabs, Pro blocking rules, toolbar button |
| `src/lib/` | pure helpers (addresses, times, blocking rules, view state, the toolbar glyph, a tiny DOM builder) |
| `pages/popup.*` | toolbar popup: not installed, not running, ready, focusing, break, free with the Pro card |
| `pages/block.*` | the page a paused or blocked tab shows (`kind=paused` with the app's fields, or the Pro `site`, `part`, `limit`) |
| `pages/options.*` | options |
| `pages/welcome.*` | first run: welcome, connect, pin, done |
| `icons/` | PNG icons, drawn by `scripts/make-icons.py` |
| `test/` | Node tests (`npm test`) |
| `scripts/smoke.mjs` | loads the extension into real Chrome against a fake app (below) |

## Permissions

| Permission | Why |
| --- | --- |
| `tabs` | the address and title of the tab in front, and pausing a tab with `tabs.update` |
| `nativeMessaging` | talking to FocusGuard on this Mac |
| `storage`, `alarms` | the extension's own settings; a timer for the toolbar button |
| `declarativeNetRequestWithHostAccess` | Pro blocking rules. No install warning; it does nothing without site access |
| optional: `<all_urls>` and `scripting` | asked for only when Pro blocking is turned on: blocking before load, the pass countdown on the page, a YouTube video's channel |

`declarativeNetRequest` itself can't be an optional permission, which is why
the `WithHostAccess` variant is used.

## Tests

```bash
npm test
```

The smoke test needs a built app (for the helper) and `puppeteer-core`
(install it anywhere, e.g. `npm i puppeteer-core` in a scratch folder, and run
from there):

```bash
node /path/to/extension/chrome/scripts/smoke.mjs --helper /path/to/FocusGuard.app/Contents/Helpers/FocusGuardBrowserHelper --out shots
```

It starts Google Chrome with a throwaway profile, connects through the real
helper to a fake app on a test socket, walks connect, tab reports, the popup's
states, pausing a tab and giving it back, the block pages, options and first
run, and saves a screenshot of each.

## Publishing (to do)

The extension isn't in any store yet. When it goes in:

1. Register a Chrome Web Store developer account (one-time fee) and create the
   item. Upload a zip of this folder **without** the `key` line.
2. The store gives the item its own ID. Either
   - copy the item's public key from the dashboard into `key` here, so the
     unpacked build gets the store ID too, and put that ID in
     `BrowserExtensionIDs.development`; or
   - keep the development key and put the store ID in
     `BrowserExtensionIDs.store` (`FocusGuard/Extension/NativeHostInstaller.swift`),
     so the host manifest allows both.
3. The listing needs a privacy policy URL, a single-purpose description and a
   reason for each permission (the table above).
4. Replace the placeholder `GET_APP_URL` in `src/lib/protocol.js` with the real
   download page.
5. Edge Add-ons is optional: Edge installs from the Chrome Web Store. A separate
   Edge listing gets another ID, which also goes in `BrowserExtensionIDs`.
