// Helpers shared by the README visuals.
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Read a captured output file from demo/ (needs --allow-file-access-from-files).
async function demo(name) {
  const r = await fetch(`demo/${name}`);
  if (!r.ok) throw new Error(`demo/${name}: ${r.status}`);
  return (await r.text()).replace(/\n$/, "");
}

const mobile = () => window.matchMedia("(max-width: 700px)").matches;

// One output line per block, so a wrapped line hangs under its first word.
const lines = (arr) => arr.map((h) => `<span class="ln">${h}</span>`).join("");

// Four countersunk screws in the corners of every .panel.
function screws() {
  for (const p of document.querySelectorAll(".panel")) {
    for (const c of ["tl", "tr", "bl", "br"]) {
      const s = document.createElement("i");
      s.className = `screw ${c}`;
      p.appendChild(s);
    }
  }
}
document.addEventListener("DOMContentLoaded", screws);

// Seven-segment digits, the way a panel meter draws them: lit segments in `color`,
// the unlit ones still faintly visible behind them. Returns an <svg> string.
// seg("05:00:02", { h: 40, color: "#f5a63c" })
function seg(text, { h = 60, color = "#f5a63c", ghost = 0.08, glow = true } = {}) {
  const W = 56, H = 100, T = 11, G = 1.6;           // one digit cell, in segment units
  const map = { 0: "abcdef", 1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc", 5: "afgcd", 6: "afgedc", 7: "abc", 8: "abcdefg", 9: "abcdfg", "-": "g", " ": "" };
  const hz = (x1, x2, y) => [[x1, y], [x1 + T / 2, y - T / 2], [x2 - T / 2, y - T / 2], [x2, y], [x2 - T / 2, y + T / 2], [x1 + T / 2, y + T / 2]];
  const vt = (x, y1, y2) => [[x, y1], [x + T / 2, y1 + T / 2], [x + T / 2, y2 - T / 2], [x, y2], [x - T / 2, y2 - T / 2], [x - T / 2, y1 + T / 2]];
  const L = T / 2, R = W - T / 2, top = T / 2, mid = H / 2, bot = H - T / 2;
  const segs = {
    a: hz(L + G, R - G, top), g: hz(L + G, R - G, mid), d: hz(L + G, R - G, bot),
    f: vt(L, top + G, mid - G), b: vt(R, top + G, mid - G),
    e: vt(L, mid + G, bot - G), c: vt(R, mid + G, bot - G),
  };
  const poly = (pts, dx) => `<polygon points="${pts.map(([px, py]) => `${(px + dx).toFixed(2)},${py.toFixed(2)}`).join(" ")}"/>`;
  let x = 0, on = "", off = "";
  for (const ch of String(text)) {
    if (ch === ":") {
      on += `<rect x="${x + 7}" y="${H * 0.27}" width="${T}" height="${T}" rx="2"/><rect x="${x + 3}" y="${H * 0.65}" width="${T}" height="${T}" rx="2"/>`;
      x += T + 16; continue;
    }
    if (ch === ".") { on += `<rect x="${x - 6}" y="${H - T}" width="${T}" height="${T}" rx="2"/>`; x += 10; continue; }
    const lit = map[ch] ?? "";
    for (const k of "abcdefg") (lit.includes(k) ? (s) => (on += s) : (s) => (off += s))(poly(segs[k], x));
    x += W + 18;
  }
  const w = x - 18 + 10, s = h / (H + 4);
  const id = "sg" + Math.random().toString(36).slice(2, 8);
  return `<svg class="seg" width="${(w * s).toFixed(1)}" height="${h}" viewBox="-4 -2 ${w} ${H + 4}" style="overflow:visible">` +
    `<defs><filter id="${id}" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="3" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>` +
    `<g transform="skewX(-6) translate(6 0)" fill="${color}"><g fill-opacity="${ghost}">${off}</g><g${glow ? ` filter="url(#${id})"` : ""}>${on}</g></g></svg>`;
}

// ---- mimic drawing helpers (inline SVG). Every <svg> gets its own defs suffix K, because
// two SVGs on one page (wide and phone) must not share gradient ids.
const defs = (k) => `<defs>
  <linearGradient id="ivory${k}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f2ecdd"/><stop offset="1" stop-color="#d9d1bc"/></linearGradient>
  <radialGradient id="lg${k}" cx=".38" cy=".32" r=".7"><stop offset="0" stop-color="#fff"/><stop offset=".18" stop-color="#b6f5cf"/><stop offset=".5" stop-color="#52d68a"/><stop offset="1" stop-color="#1f6b43"/></radialGradient>
  <radialGradient id="la${k}" cx=".38" cy=".32" r=".7"><stop offset="0" stop-color="#fff"/><stop offset=".18" stop-color="#ffe2b0"/><stop offset=".5" stop-color="#f5a63c"/><stop offset="1" stop-color="#8a5310"/></radialGradient>
  <radialGradient id="win${k}" cx=".5" cy=".5" r=".7"><stop offset="0" stop-color="#ffe0a8"/><stop offset=".6" stop-color="#f5a63c"/><stop offset="1" stop-color="#d07d1c"/></radialGradient>
  <filter id="glow${k}" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="3" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  <filter id="halo${k}" x="-200%" y="-200%" width="500%" height="500%"><feGaussianBlur stdDeviation="9"/></filter>
</defs>`;
let K = "";
const lamp = (x, y, c = "g") => `<g transform="translate(${x} ${y})"><circle r="8" fill="#050c13"/><circle r="7" fill="none" stroke="#2b4054" stroke-width="1.4"/><circle r="5.2" fill="url(#l${c}${K})" filter="url(#glow${K})"/></g>`;
const T = (cls, x, y, txt, anchor) => `<text class="${cls}" x="${x}" y="${y}"${anchor ? ` text-anchor="${anchor}"` : ""}>${txt}</text>`;

const padlock = (x, y) => `<g transform="translate(${x} ${y})"><path d="M2.5 0 V-3.5 a4.5 4.5 0 0 1 9 0 V0" fill="none" stroke="var(--engrave)" stroke-width="2"/><rect x="0" y="0" width="14" height="11" rx="1.5" fill="var(--engrave)"/><circle cx="7" cy="5" r="1.6" fill="var(--enamel)"/></g>`;
