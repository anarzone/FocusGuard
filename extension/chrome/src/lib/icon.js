// Draws the toolbar shield for chrome.action.setIcon. The same shapes as the
// menu-bar glyph: outline when ready, filling from the bottom while a
// session runs, grey when paused, a cup on a break, a check when done, and
// slashed grey when the app isn't connected.

export const SHIELD = 'M8 1.6l5.1 2.1v3.7c0 3.1-2.1 5.8-5.1 7-3-1.2-5.1-3.9-5.1-7V3.7L8 1.6z';
const SHIELD_TOP = 1.6;
const SHIELD_BOTTOM = 14.4;
const CUP = [
  'M3.2 6.4h7.6v3a3.4 3.4 0 0 1-3.4 3.4H6.6a3.4 3.4 0 0 1-3.4-3.4z',
  'M10.8 7.4h0.9a1.6 1.6 0 0 1 0 3.2h-1.2',
  'M5.8 2.6v2',
  'M8.2 2.6v2',
];
const CHECK = 'M5.4 8.1l1.8 1.8 3.4-3.6';

export const palette = (dark) => ({
  indigo: dark ? '#6D7CFF' : '#6155F5',
  off: dark ? '#98989D' : '#8E8E93',
  ready: dark ? '#D1D1D6' : '#55555E',
  checkInk: dark ? '#1D1D1F' : '#FFFFFF',
});

// Top of the fill for a session `fill` share done (0…1), in glyph units.
export function fillTop(fill) {
  const f = Math.min(1, Math.max(0, fill));
  return SHIELD_BOTTOM - f * (SHIELD_BOTTOM - SHIELD_TOP);
}

export function drawGlyph(kind, fill, size, dark) {
  const canvas = new OffscreenCanvas(size, size);
  const ctx = canvas.getContext('2d');
  const colors = palette(dark);
  ctx.scale(size / 16, size / 16);
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.lineWidth = size >= 32 ? 1.2 : 1.4;
  const shield = new Path2D(SHIELD);

  const fillFrom = (top, color) => {
    ctx.save();
    ctx.clip(shield);
    ctx.fillStyle = color;
    ctx.fillRect(0, top, 16, 16 - top);
    ctx.restore();
  };

  switch (kind) {
    case 'off': {
      ctx.strokeStyle = colors.off;
      ctx.stroke(shield);
      // Cut a gap either side of the slash, then draw it.
      ctx.save();
      ctx.globalCompositeOperation = 'destination-out';
      ctx.lineWidth = 3.2;
      ctx.beginPath();
      ctx.moveTo(2.6, 13.4);
      ctx.lineTo(13.4, 2.6);
      ctx.stroke();
      ctx.restore();
      ctx.beginPath();
      ctx.moveTo(2.6, 13.4);
      ctx.lineTo(13.4, 2.6);
      ctx.stroke();
      break;
    }
    case 'focus':
      fillFrom(fillTop(fill), colors.indigo);
      ctx.strokeStyle = colors.indigo;
      ctx.stroke(shield);
      break;
    case 'paused':
      fillFrom(fillTop(fill), colors.off);
      ctx.strokeStyle = colors.off;
      ctx.stroke(shield);
      break;
    case 'break':
      ctx.strokeStyle = colors.indigo;
      for (const d of CUP) ctx.stroke(new Path2D(d));
      break;
    case 'done':
      ctx.fillStyle = colors.indigo;
      ctx.fill(shield);
      ctx.strokeStyle = colors.indigo;
      ctx.stroke(shield);
      ctx.strokeStyle = colors.checkInk;
      ctx.lineWidth = 1.6;
      ctx.stroke(new Path2D(CHECK));
      break;
    default:
      ctx.strokeStyle = colors.ready;
      ctx.stroke(shield);
  }
  return ctx.getImageData(0, 0, size, size);
}

export function glyphImages(kind, fill, dark) {
  return { 16: drawGlyph(kind, fill, 16, dark), 32: drawGlyph(kind, fill, 32, dark) };
}
