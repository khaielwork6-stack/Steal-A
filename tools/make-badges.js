// Draws the 512x512 placeholder badge PNGs (no text) into assets/badges.
// Usage: node tools/make-badges.js
const fs = require("fs");
const zlib = require("zlib");
const path = require("path");

const S = 512, SS = 3; // size, supersample per axis
const C = S / 2;

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(rgba) {
  const raw = Buffer.alloc((S * 4 + 1) * S);
  for (let y = 0; y < S; y++) { raw[y * (S * 4 + 1)] = 0; rgba.copy(raw, y * (S * 4 + 1) + 1, y * S * 4, (y + 1) * S * 4); }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(S, 0); ihdr.writeUInt32BE(S, 4); ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
}
const hex = (h) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
const mix = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);

// ---- shape tests (x, y in badge space, centre 0,0, radius ~1) ----
function inPoly(x, y, pts) {
  let inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i], [xj, yj] = pts[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
function star(points, outer, inner, rot = -Math.PI / 2, cy = 0) {
  const pts = [];
  for (let i = 0; i < points * 2; i++) {
    const r = i % 2 ? inner : outer, a = rot + (i * Math.PI) / points;
    pts.push([Math.cos(a) * r, Math.sin(a) * r + cy]);
  }
  return pts;
}
const shapes = {
  // Faceted gem.
  gem: (x, y, g) => inPoly(x, y, [[-0.42 - g, -0.2 - g], [-0.22, -0.42 - g], [0.22, -0.42 - g], [0.42 + g, -0.2 - g], [0, 0.46 + g * 1.4]]),
  gemFacet: (x, y) => inPoly(x, y, [[-0.42, -0.2], [0.42, -0.2], [0, 0.46]]) && x < 0,
  // Treasure chest.
  chest: (x, y, g) => (Math.abs(x) < 0.44 + g && y > -0.12 - g && y < 0.36 + g) || (Math.abs(x) < 0.44 + g && y > -0.36 - g && y <= -0.12 && Math.hypot(x / (0.44 + g), (y + 0.12) / (0.26 + g)) < 1),
  chestBand: (x, y) => Math.abs(y + 0.1) < 0.035 && Math.abs(x) < 0.44,
  chestLock: (x, y) => Math.abs(x) < 0.08 && y > -0.16 && y < 0.06,
  // Eight-point burst.
  burst: (x, y, g) => inPoly(x, y, star(8, 0.5 + g, 0.24 + g * 0.6)),
  burstCore: (x, y) => Math.hypot(x, y) < 0.17,
  // Crown.
  crown: (x, y, g) => inPoly(x, y, [[-0.46 - g, 0.3 + g], [0.46 + g, 0.3 + g], [0.48 + g, -0.3 - g], [0.24, -0.02], [0, -0.4 - g], [-0.24, -0.02], [-0.48 - g, -0.3 - g]]),
  crownBand: (x, y) => y > 0.16 && y < 0.3 && Math.abs(x) < 0.46,
  crownJewel: (x, y) => Math.hypot(x, y - 0.06) < 0.07,
  // Flame (teardrop + inner flame).
  flame: (x, y, g) => {
    const r = 0.34 + g;
    if (y > 0.02) return Math.hypot(x, (y - 0.14) * 1.05) < r;
    const t = (0.02 - y) / 0.6; // 0 at the widest, 1 at the tip
    return t < 1.0 + g && Math.abs(x - Math.sin(t * 2.2) * 0.1 * t) < r * (1 - t) * 1.05 + g * 0.6;
  },
  flameInner: (x, y) => {
    if (y > 0.16) return Math.hypot(x, (y - 0.24)) < 0.15;
    const t = (0.16 - y) / 0.34;
    return t < 1 && Math.abs(x) < 0.15 * (1 - t);
  },
};

const BADGES = [
  { file: "FirstSteal", base: "#2fbf71", deep: "#11663a", ring: "#b8ffcf", emblem: "gem", fill: "#7fe7ff", fill2: "#2aa6ff", extra: [["gemFacet", "#c8f6ff"]] },
  { file: "FirstReveal", base: "#ff9d2e", deep: "#9c4a00", ring: "#ffe0a8", emblem: "chest", fill: "#a8643a", fill2: "#6e3b1d", extra: [["chestBand", "#ffd34d"], ["chestLock", "#ffd34d"]] },
  { file: "FirstMythicReveal", base: "#ff4a6a", deep: "#7a0f2a", ring: "#ffc2cf", emblem: "burst", fill: "#fff1a6", fill2: "#ffb300", extra: [["burstCore", "#ffffff"]] },
  { file: "Steals100", base: "#7b5cff", deep: "#2d1a8a", ring: "#d7ccff", emblem: "crown", fill: "#ffe066", fill2: "#f0a000", extra: [["crownBand", "#d98a00"], ["crownJewel", "#ff4a6a"]] },
  { file: "Streak7", base: "#2aa6ff", deep: "#0b3f7a", ring: "#bfe6ff", emblem: "flame", fill: "#ffd24d", fill2: "#ff5a1f", extra: [["flameInner", "#fff4b0"]] },
];

const OUTLINE = hex("#1b1030");
for (const b of BADGES) {
  const img = Buffer.alloc(S * S * 4);
  const base = hex(b.base), deep = hex(b.deep), ring = hex(b.ring), f1 = hex(b.fill), f2 = hex(b.fill2);
  for (let py = 0; py < S; py++) {
    for (let px = 0; px < S; px++) {
      let acc = [0, 0, 0, 0];
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const x = (px + (sx + 0.5) / SS - C) / (C * 0.92);
          const y = (py + (sy + 0.5) / SS - C) / (C * 0.92);
          const r = Math.hypot(x, y);
          let col = null;
          if (r <= 1) {
            if (r > 0.93) col = OUTLINE; // outer outline
            else if (r > 0.82) col = mix(ring, mix(ring, deep, 0.35), (y + 1) / 2); // bevel ring
            else if (r > 0.79) col = OUTLINE;
            else {
              // disc: top-to-bottom gradient + soft vignette
              col = mix(mix(base, [255, 255, 255], 0.18), deep, Math.min(1, (y + 0.8) / 1.7));
              col = mix(col, deep, Math.max(0, r - 0.55) * 0.9);
              // rays
              const a = Math.atan2(y, x);
              if (Math.cos(a * 12) > 0.6) col = mix(col, [255, 255, 255], 0.06);
              const sh = shapes[b.emblem];
              const ex = x, ey = y;
              if (sh(ex + 0.02, ey - 0.05, 0.0)) col = mix(col, [0, 0, 0], 0.35); // drop shadow
              if (sh(ex, ey, 0.05)) col = OUTLINE; // emblem outline
              if (sh(ex, ey, 0)) {
                col = mix(f1, f2, Math.min(1, Math.max(0, (ey + 0.45) / 0.9)));
                for (const [name, c] of b.extra) if (shapes[name](ex, ey)) col = hex(c);
              }
              // glossy highlight on the top of the disc
              const hx = x / 0.62, hy = (y + 0.42) / 0.3;
              if (hx * hx + hy * hy < 1) col = mix(col, [255, 255, 255], 0.22 * (1 - (hx * hx + hy * hy)));
            }
          }
          if (col) { acc[0] += col[0]; acc[1] += col[1]; acc[2] += col[2]; acc[3] += 255; }
        }
      }
      const n = SS * SS, o = (py * S + px) * 4, cov = acc[3] / 255;
      if (cov > 0) { img[o] = acc[0] / cov; img[o + 1] = acc[1] / cov; img[o + 2] = acc[2] / cov; }
      img[o + 3] = acc[3] / n;
    }
  }
  fs.mkdirSync(path.join(__dirname, "..", "assets", "badges"), { recursive: true });
  fs.writeFileSync(path.join(__dirname, "..", "assets", "badges", b.file + ".png"), png(img));
  console.log("wrote", b.file);
}
