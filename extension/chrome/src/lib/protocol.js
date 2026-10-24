// Messages between the extension and the FocusGuard app. The other half is
// FocusGuard/Extension/BrowserMessage.swift; keep the two in step.
//
// Path: extension → (native port) → FocusGuardBrowserHelper → (Unix socket)
// → FocusGuard.app. Nothing goes over the network.

export const HOST_NAME = 'com.anar.focusguard';
export const PROTOCOL_VERSION = 1;

// Placeholder until there's a download page.
export const GET_APP_URL = 'https://github.com/anarzone/FocusGuard/releases/latest';

// Connection states the popup and pages show.
export const Conn = Object.freeze({
  connecting: 'connecting',
  // The browser has no host manifest: FocusGuard isn't installed (or has
  // never been opened, which is when it writes the manifest).
  notInstalled: 'notInstalled',
  // The helper answered, but the app isn't running.
  notRunning: 'notRunning',
  connected: 'connected',
});

// Requests that wait for an answer from the app.
export const REQUEST_TIMEOUT_MS = 4000;

let counter = 0;
export function requestId() {
  counter = (counter + 1) % 1e9;
  return `${Date.now().toString(36)}-${counter}`;
}

// The connection status from a connectNative failure message.
export function connFromDisconnect(message) {
  const text = String(message || '');
  if (/not found|forbidden/i.test(text)) return Conn.notInstalled;
  return Conn.notRunning;
}

// Pages call into the background with runtime messages of these types.
export const PageMessage = Object.freeze({
  snapshot: 'snapshot',     // background → page: { conn, state, settings, ... }
  request: 'request',       // page → background: forward to the app, await the reply
  reconnect: 'reconnect',   // page → background: try connecting again now
  setSetting: 'setSetting', // page → background: { key, value }
  reopenTab: 'reopenTab',   // block page → background: give the paused tab back
  closeTab: 'closeTab',     // block page → background
  passThrough: 'passThrough', // block page → background: request a pass, then load the page
  forWork: 'forWork',       // block page → background
  extraTime: 'extraTime',   // block page → background
  blockedVisit: 'blockedVisit', // block page → background
  appearance: 'appearance', // page → background: { dark } for the toolbar glyph
  goTo: 'goTo',             // block page → background: navigate this tab
});
