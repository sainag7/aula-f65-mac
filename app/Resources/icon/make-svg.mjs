// Writes the Wave app icon (logo B on mockups/f65-logos.html) as SVG:
//   AppIcon.svg        full 65% layout, used from 128 px up
//   AppIcon-small.svg  three chunky rows, used at 16–64 px where the full layout turns to mush
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));

function base(inner, glow = 34) {
  return `<svg viewBox="0 0 1024 1024" width="1024" height="1024" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#22252B"/><stop offset="1" stop-color="#08090B"/></linearGradient>
    <linearGradient id="hl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <filter id="sh" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#000" flood-opacity=".45"/></filter>
    <filter id="blur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="${glow}"/></filter>
  </defs>
  <rect x="100" y="100" width="824" height="824" rx="186" fill="url(#bg)" filter="url(#sh)"/>
  <rect x="101" y="101" width="822" height="822" rx="185" fill="none" stroke="url(#hl)" stroke-width="3"/>
  ${inner}
</svg>
`;
}
// The wave runs amber → coral → magenta → cyan, left to right with a slight downward slant.
const colour = (t) => `hsl(${((40 - t * 230 + 360) % 360).toFixed(1)} 92% ${(62 - t * 6).toFixed(1)}%)`;

function keyboard(rows, units, unit, key, radius, plate) {
  const width = units * unit - (unit - key), height = rows.length * unit - (unit - key);
  const x0 = 512 - width / 2, y0 = 512 - height / 2;
  let keys = "", glow = "";
  rows.forEach((row, r) => {
    let x = 0;
    for (const w of row) {
      const kx = x0 + x * unit, ky = y0 + r * unit, kw = w * unit - (unit - key);
      const t = Math.min(1, Math.max(0, ((x + w / 2) / units) * 0.85 + r * (0.25 / rows.length)));
      const c = colour(t);
      keys += `<rect x="${kx.toFixed(1)}" y="${ky.toFixed(1)}" width="${kw.toFixed(1)}" height="${key}" rx="${radius}" fill="${c}"/>`;
      glow += `<rect x="${kx.toFixed(1)}" y="${ky.toFixed(1)}" width="${kw.toFixed(1)}" height="${key}" fill="${c}"/>`;
      x += w;
    }
  });
  const p = plate;
  return `<rect x="${(x0 - p).toFixed(1)}" y="${(y0 - p).toFixed(1)}" width="${(width + 2 * p).toFixed(1)}" height="${(height + 2 * p).toFixed(1)}" rx="${(radius * 2.2).toFixed(1)}" fill="#0E1013" stroke="#ffffff" stroke-opacity=".06" stroke-width="3"/>
  <g filter="url(#blur)" opacity=".75">${glow}</g><g>${keys}</g>`;
}

// The F65's 65 % layout, 16 units wide.
const full = [[1,1,1,1,1,1,1,1,1,1,1,1,1,2,1],[1.5,1,1,1,1,1,1,1,1,1,1,1,1,1.5,1],[1.75,1,1,1,1,1,1,1,1,1,1,1,2.25,1],[2.25,1,1,1,1,1,1,1,1,1,1,1.75,1,1],[1.25,1.25,1.25,6.25,1,1,1,1,1,1]];
const small = [[1,1,1,1,1],[1,1,1,1,1],[1,3,1]];
writeFileSync(join(here, "AppIcon.svg"), base(keyboard(full, 16, 44, 38, 8, 20)));
writeFileSync(join(here, "AppIcon-small.svg"), base(keyboard(small, 5, 132, 108, 22, 30), 40));
console.log("Wrote AppIcon.svg and AppIcon-small.svg");
