// A small element builder and the icons the pages share. Pages build their
// DOM with h(); nothing is parsed from strings.

import { SHIELD, fillTop } from './icon.js';
import { tileLetter } from './format.js';

const SVG_NS = 'http://www.w3.org/2000/svg';
const SVG_TAGS = new Set(['svg', 'path', 'circle', 'rect', 'g', 'defs', 'clipPath', 'text', 'line']);

export function h(tag, props, ...children) {
  const el = SVG_TAGS.has(tag) ? document.createElementNS(SVG_NS, tag) : document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') el.setAttribute('class', value);
    else if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key === 'style' && typeof value === 'object') Object.assign(el.style, value);
    else if (key === 'text') el.textContent = value;
    else el.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

// Replaces `parent`'s content, skipping the nulls views use for "nothing
// here" (replaceChildren would print them).
export function mount(parent, children) {
  parent.replaceChildren(...[children].flat(Infinity).filter((c) => c !== null && c !== undefined && c !== false));
}

let clipCounter = 0;

// The shield, optionally filling from the bottom (0…1).
export function shieldIcon({ size = 22, fill = 0, color = 'var(--ink-2)', solid = false, slashed = false, check = false } = {}) {
  const id = `fg-clip-${++clipCounter}`;
  const svg = h('svg', { width: size, height: size, viewBox: '0 0 16 16', 'aria-hidden': 'true' });
  if (solid) {
    svg.append(h('path', { d: SHIELD, fill: color, stroke: color, 'stroke-width': 1.3, 'stroke-linejoin': 'round' }));
  } else {
    if (fill > 0) {
      svg.append(h('defs', null, h('clipPath', { id }, h('path', { d: SHIELD }))));
      svg.append(h('rect', { x: 0, y: fillTop(fill), width: 16, height: 16, fill: color, 'clip-path': `url(#${id})` }));
    }
    svg.append(h('path', { d: SHIELD, fill: 'none', stroke: color, 'stroke-width': 1.3, 'stroke-linejoin': 'round' }));
  }
  if (slashed) {
    svg.append(h('path', { d: 'M2.6 13.4L13.4 2.6', stroke: 'var(--slash-gap, var(--popup))', 'stroke-width': 3 }));
    svg.append(h('path', { d: 'M2.6 13.4L13.4 2.6', stroke: color, 'stroke-width': 1.3, 'stroke-linecap': 'round' }));
  }
  if (check) {
    svg.append(h('path', { d: 'M5.4 8.1l1.8 1.8 3.4-3.6', fill: 'none', stroke: '#FFFFFF', 'stroke-width': 1.5, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }));
  }
  return svg;
}

// The app icon: white shield half filled with indigo on a light tile.
export function appIcon(size = 56) {
  const id = `fg-clip-${++clipCounter}`;
  return h('div', { class: 'app-icon', style: { width: `${size}px`, height: `${size}px` }, 'aria-hidden': 'true' },
    h('svg', { width: size * 0.64, height: size * 0.64, viewBox: '0 0 16 16' },
      h('defs', null, h('clipPath', { id }, h('path', { d: SHIELD }))),
      h('path', { d: SHIELD, fill: '#FFFFFF' }),
      h('rect', { x: 0, y: 5.9, width: 16, height: 10, fill: '#6155F5', 'clip-path': `url(#${id})` })));
}

function strokeIcon(paths, { size = 16, color = 'currentColor', width = 1.3, viewBox = '0 0 16 16' } = {}) {
  return h('svg', {
    width: size, height: size, viewBox, fill: 'none', stroke: color, 'stroke-width': width,
    'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true',
  }, paths.map((d) => h('path', { d })));
}

export const icons = {
  cup: (o) => strokeIcon(['M3.2 6.4h7.6v3a3.4 3.4 0 0 1-3.4 3.4H6.6a3.4 3.4 0 0 1-3.4-3.4z', 'M10.8 7.4h0.9a1.6 1.6 0 0 1 0 3.2h-1.2', 'M5.8 2.6v2', 'M8.2 2.6v2'], o),
  sliders: (o) => h('svg', { width: 16, height: 16, viewBox: '0 0 16 16', fill: 'none', stroke: 'currentColor', 'stroke-width': 1.3, 'stroke-linecap': 'round', 'aria-hidden': 'true', ...o },
    h('path', { d: 'M2.5 4.5h7M12.5 4.5h1M2.5 11.5h1M6.5 11.5h7' }), h('circle', { cx: 11, cy: 4.5, r: 1.5 }), h('circle', { cx: 5, cy: 11.5, r: 1.5 })),
  chevron: (o) => strokeIcon(['M2.5 4l2.5 2.5L7.5 4'], { size: 9, viewBox: '0 0 10 10', width: 1.5, ...o }),
  check: (o) => strokeIcon(['M3 7.2l2.6 2.6L11 4.4'], { size: 14, viewBox: '0 0 14 14', width: 1.6, ...o }),
  lock: (o) => h('svg', { width: 14, height: 14, viewBox: '0 0 12 12', fill: 'none', stroke: 'currentColor', 'stroke-width': 1.2, 'aria-hidden': 'true', ...o },
    h('rect', { x: 2.2, y: 5.2, width: 7.6, height: 5.6, rx: 1.4 }), h('path', { d: 'M4 5.2V3.8a2 2 0 0 1 4 0v1.4' })),
  tabPause: (o) => h('svg', { width: 14, height: 14, viewBox: '0 0 16 16', fill: 'none', stroke: 'currentColor', 'stroke-width': 1.4, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true', ...o },
    h('rect', { x: 1.8, y: 3, width: 12.4, height: 10, rx: 2 }), h('path', { d: 'M6.5 6.2v3.6M9.5 6.2v3.6' })),
  pauseBars: (o) => strokeIcon(['M5.5 3.5v9M10.5 3.5v9'], { width: 1.4, ...o }),
  clock: (o) => h('svg', { width: 15, height: 15, viewBox: '0 0 16 16', fill: 'none', stroke: 'currentColor', 'stroke-width': 1.3, 'stroke-linecap': 'round', 'aria-hidden': 'true', ...o },
    h('circle', { cx: 8, cy: 8, r: 6.2 }), h('path', { d: 'M8 4.8V8l2.2 1.4' })),
  arrow: (o) => strokeIcon(['M2.5 6h7M6.5 3l3 3-3 3'], { size: 12, viewBox: '0 0 12 12', width: 1.5, ...o }),
  dot: (color) => h('span', { class: 'swatch', style: { background: color, width: '9px', height: '9px', borderRadius: '3px' } }),
  yes: (o) => strokeIcon(['M3.5 8.4l2.9 2.9 6.1-6.6'], { size: 14, width: 1.6, ...o }),
  no: (o) => strokeIcon(['M4.5 4.5l7 7M11.5 4.5l-7 7'], { size: 14, width: 1.5, ...o }),
};

// The first letter of a site on a dark square, a stable shade per site.
export function siteTile(host, { size = 22, round = false } = {}) {
  const shades = ['#1D1D1F', '#24292F', '#3A3A42', '#55555E', '#3B4A6B', '#4B3FD9'];
  let hash = 0;
  for (const ch of String(host)) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  return h('span', {
    class: 'tile', 'aria-hidden': 'true',
    style: {
      width: `${size}px`, height: `${size}px`, borderRadius: round ? `${size / 2}px` : '6px',
      background: shades[hash % shades.length], fontSize: `${Math.round(size * 0.55)}px`,
    },
  }, tileLetter(host));
}

// A ring-style countdown for a button that unlocks after a wait.
export function waitDial(secondsLeft, total) {
  const done = Math.max(0, Math.min(1, 1 - secondsLeft / total));
  const angle = done * 360;
  const t = ((angle - 90) * Math.PI) / 180;
  const x = 10 + 8 * Math.cos(t);
  const y = 10 + 8 * Math.sin(t);
  return h('svg', { width: 20, height: 20, viewBox: '0 0 20 20', 'aria-hidden': 'true' },
    h('circle', { cx: 10, cy: 10, r: 8, fill: 'none', stroke: 'var(--fill-3)', 'stroke-width': 2 }),
    done > 0 ? h('path', { d: `M10 2 A8 8 0 ${angle > 180 ? 1 : 0} 1 ${x.toFixed(2)} ${y.toFixed(2)}`, fill: 'none', stroke: 'var(--ink-3)', 'stroke-width': 2, 'stroke-linecap': 'round' }) : null,
    h('text', { x: 10, y: 13.4, 'font-size': 9, fill: 'var(--ink-2)', 'text-anchor': 'middle', 'font-weight': 600, 'font-family': 'inherit' }, String(Math.ceil(secondsLeft))));
}

// Tells the background the page's light or dark look, for the toolbar glyph.
export function reportAppearance() {
  const query = matchMedia('(prefers-color-scheme: dark)');
  const send = () => chrome.runtime.sendMessage({ type: 'appearance', dark: query.matches }).catch(() => {});
  send();
  query.addEventListener('change', send);
}

// Live state from the background: calls `onSnapshot` now and on every change.
export function subscribe(name, onSnapshot) {
  const port = chrome.runtime.connect({ name });
  port.onMessage.addListener((message) => {
    if (message?.type === 'snapshot') onSnapshot(message);
  });
  return port;
}

export function ask(payload) {
  return chrome.runtime.sendMessage({ type: 'request', payload });
}

export function tell(message) {
  return chrome.runtime.sendMessage(message);
}
