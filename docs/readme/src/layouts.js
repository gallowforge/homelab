// homelab README: every composition in the Glass language (glass/scene.js renders them).
// Positions are the apparent centre in CSS px (y down); w or h is the apparent content size;
// z is depth (+ toward the viewer; 1 unit = 1 px at z = 0); rot is in degrees.
// A window with `parent` is a part of that window's content lifted out toward the viewer
// (`src` is the part, in texture pixels, from shots/boxes.js).
import { BOXES } from './shots/boxes.js';

const NIGHT = {
  page: '#0d1117',
  env: { top: '#090c12', bot: '#05070a', haze: '#18202c', hazeStr: 0.10, ray: '#a8e0c4',
    shafts: [[0.16, 0.050, 0.05, 0.12], [0.33, 0.022, 0.03, 0.08], [0.64, 0.028, -0.03, 0.09], [0.84, 0.060, -0.06, 0.12], [0.50, 0.20, 0.0, 0.04]],
    glows: [[0.50, 0.46, 0.46, 0.08, '#1d6a4c'], [0.5, 1.15, 0.65, 0.08, '#8ea6d8']] },
  glass: { tint: [0.062, 0.068, 0.082], transmit: 0.80, fog: '#090c12', light: [-700, 800, 900], rim: 0.9, spec: 0.40, glow: 0.62, shadow: 0.30, levels: 5, caustic: 0 },
  motes: { n: 70, color: '#d4ffe8', amt: 0.45 },
  bloom: 0.40, bloomThresh: 0.55,
};
const DAY = {
  page: '#ffffff',
  env: { top: '#eef2f2', bot: '#f6f8f7', haze: '#ffffff', hazeStr: 0.04, shadeCol: '#e9eeee', sun: [0.30, 0, -1.0, 1.0], dapple: 0.55, sunStr: 0.075, sunCol: '#fff4e2',
    shadow: 0.55, caustic: 0.10, shadowDir: [0.05, -0.075], glows: [] },
  glass: { tint: [0.075, 0.078, 0.084], transmit: 0.88, fog: '#edf1f1', light: [-700, 800, 900], rim: 0.95, spec: 0.30, glow: 0.0, shadow: 0.12, levels: 5, caustic: 0 },
  motes: { n: 40, color: '#fffaf0', amt: 0.45 },
  bloom: 0.0, bloomThresh: 0.95,
};
const merge = (a, b) => { const o = { ...a }; for (const k in b) o[k] = (b[k] && typeof b[k] === 'object' && !Array.isArray(b[k])) ? merge(a[k] || {}, b[k]) : b[k]; return o; };
const C = {
  kick: { night: { color: 'rgba(205,214,228,0.56)' }, day: { color: '#7b8291' } },
  name: { night: { color: '#f5f7fb' }, day: { color: '#0b0d11' } },
  line: { night: { color: 'rgba(222,229,240,0.74)' }, day: { color: '#4a5161' } },
};
const T = (cls, html, x, y, style = {}, align) => ({ cls, html, x, y, align, style, ...C[cls] });

// the window content: one PNG per theme, made by textures.mjs
const tex = (name, n) => `${name}-${n ? 'dark' : 'light'}.png`;
const full = (name) => [0, 0, ...BOXES[name].size];
const pad = (b, x, y = x) => [b[0] - x, b[1] - y, b[2] + 2 * x, b[3] + 2 * y];
const W = (name, n, o) => ({ tex: tex(name, n), crop: full(name), key: n ? '#0A0D12' : '#FBFBFC', keyAmt: n ? 0.6 : 0.72, bezel: 9, glowColor: '#174836', ...o });
const LIFT = (parent, src, n, o) => ({ parent, src, lift: 90, breathe: [10, 0.25], bezel: 8, radius: 12, key: n ? '#0A0D12' : '#FBFBFC', keyAmt: n ? 0.72 : 0.85,
  shadowOff: n ? [0, -14, 36] : [10, -20, 24], shadow: n ? 0.45 : 0.22, glow: 0.3, glowColor: '#1f6a4c', ...o });
const FAR = (n) => ({ lod: 1.1, defocus: 2.4, fog: n ? 0.60 : 0.38 });
const MID = (n) => ({ lod: 0.4, defocus: 0.8, fog: n ? 0.20 : 0.10 });

// every panel: 840 CSS px wide at 2x for desktops, 381 px at 1080/381 for phones
const PANEL = (h, win, o = {}) => ({ css: [840, h], fade: [36, 36, 28, 34], cam: [12, 5], pool: o.pool || [0.5, 0.5, 0.78, 0.86],
  night: merge(NIGHT, o.night || {}), day: merge(DAY, o.day || {}), windows: win, type: o.type || [] });
const PHONE = (h, win, o = {}) => ({ css: [381, h], dpr: 1080 / 381, fade: [16, 16, 22, 26], cam: [7, 3], pool: o.pool || [0.5, 0.5, 0.80, 0.80],
  night: merge(NIGHT, o.night || {}), day: merge(DAY, o.day || {}), windows: win, type: o.type || [] });

// ---------- the hero ----------
const HERO_NIGHT = merge(NIGHT, { env: {
  shafts: [[0.30, 0.050, 0.05, 0.14], [0.42, 0.020, 0.02, 0.10], [0.58, 0.022, -0.02, 0.11], [0.71, 0.050, -0.05, 0.14], [0.50, 0.22, 0.0, 0.06]],
  glows: [[0.50, 0.38, 0.40, 0.13, '#1f8a66'], [0.5, 1.15, 0.65, 0.10, '#8ea6d8'], [0.5, -0.15, 0.6, 0.05, '#3f6a5e']] } });
const HERO_DAY = merge(DAY, { env: { sun: [0.10, 0, -0.80, 0.95] } });
const heroWindows = (n, P) => [
  W('topology', n, { ...P[0], ...FAR(n), breathe: [16, 0.15], bezel: 8 }),
  W('charter', n, { ...P[1], ...FAR(n), breathe: [12, 0.8], bezel: 8 }),   // landscape page
  W('backup', n, { ...P[2], ...MID(n), breathe: [12, 0.5] }),
  W('apply', n, { ...P[3], ...MID(n), breathe: [12, 0.0] }),
  W('drill', n, { ...P[4], breathe: [10, 0.6], bezel: 11, glow: 0.8 }),
  W('phone', n, { ...P[5], breathe: [9, 0.3], bezel: 9, glowColor: '#3a2420' }),
  LIFT(4, pad(BOXES.drill.sum, 22, 12), n, { lift: 120, breathe: [12, 0.85], ...(P[6] || {}) }),
];
const HERO_LINE = 'Fifteen services on a Raspberry Pi 5, managed as code, with backups that prove themselves.';

export const LAYOUTS = {
  hero: {
    css: [840, 540], dpr: 2, fade: [40, 40, 30, 46], cam: [0, 0], motion: 0, pool: [0.5, 0.42, 0.62, 0.62],
    night: HERO_NIGHT, day: HERO_DAY,
    windows: (n) => heroWindows(n, [
      { x: 104, y: 196, w: 118, z: -820, rot: [10, 18, 0] },
      { x: 736, y: 196, w: 118, z: -820, rot: [10, -18, 0] },
      { x: 124, y: 318, w: 210, z: -320, rot: [2, 32, 0] },
      { x: 716, y: 318, w: 210, z: -320, rot: [2, -32, 0] },
      { x: 420, y: 352, w: 430, z: 40, rot: [3, 0, 0] },
      { x: 676, y: 414, w: 196, z: 170, rot: [0, -14, 0] },
    ]),
    type: [
      T('name', 'homelab', 420, 34, { fontSize: '60px' }, 'center'),
      T('line', HERO_LINE, 420, 110, { fontSize: '16.5px' }, 'center'),
    ],
  },
  'hero-phone': {
    css: [381, 600], dpr: 1080 / 381, fade: [16, 16, 24, 30], cam: [0, 0], motion: 0, pool: [0.5, 0.40, 0.75, 0.55],
    night: HERO_NIGHT, day: HERO_DAY,
    windows: (n) => heroWindows(n, [
      { x: 86, y: 226, w: 96, z: -820, rot: [10, 18, 0] },
      { x: 296, y: 226, w: 96, z: -820, rot: [10, -18, 0] },
      { x: 62, y: 300, w: 150, z: -320, rot: [2, 32, 0] },
      { x: 320, y: 300, w: 150, z: -320, rot: [2, -32, 0] },
      { x: 186, y: 366, w: 296, z: 40, rot: [3, 0, 0] },
      { x: 296, y: 482, w: 146, z: 170, rot: [0, -14, 0] },
      { lift: 70, breathe: [8, 0.85] },
    ]),
    type: [
      T('name', 'homelab', 190.5, 34, { fontSize: '50px' }, 'center'),
      T('line', 'Fifteen services on a Raspberry Pi 5,<br>managed as code, with backups<br>that prove themselves.', 190.5, 96, { fontSize: '15px', textAlign: 'center' }, 'center'),
    ],
  },

  // ---------- the numbers band ----------
  numbers: PANEL(210, (n) => [W('numbers', n, { x: 420, y: 104, w: 760, z: 0, rot: [7, 0, 0], bezel: 6, breathe: [0, 0], key: n ? '#0A0D12' : '#FBFBFC', keyAmt: n ? 0.85 : 0.92, glow: 0.35, bar: false })],
    { pool: [0.5, 0.5, 0.80, 0.95] }),
  'numbers-phone': PHONE(300, (n) => [W('numbers-phone', n, { x: 190.5, y: 150, w: 336, z: 0, rot: [8, 0, 0], bezel: 6, breathe: [0, 0], keyAmt: n ? 0.85 : 0.92, glow: 0.35, bar: false })]),

  // ---------- 1. backups: verified before anything is pruned ----------
  backups: PANEL(400, (n) => [
    W('backup', n, { x: 330, y: 186, w: 480, z: -60, rot: [2, 16, 0], breathe: [8, 0.0], bezel: 10 }),
    W('fail', n, { x: 586, y: 292, w: 420, z: 90, rot: [0, -12, 0], breathe: [8, 0.45], glowColor: '#4a1f1a' }),
  ]),
  'backups-phone': PHONE(470, (n) => [
    W('backup', n, { x: 182, y: 180, w: 326, z: -60, rot: [2, 12, 0], breathe: [8, 0.0] }),
    W('fail', n, { x: 196, y: 352, w: 300, z: 90, rot: [0, -10, 0], breathe: [8, 0.45], glowColor: '#4a1f1a' }),
  ]),

  // ---------- 2. the weekly restore drill ----------
  drill: PANEL(400, (n) => [
    W('topology', n, { x: 690, y: 170, w: 250, z: -520, rot: [6, -24, 0], ...FAR(n), breathe: [10, 0.6] }),
    W('drill', n, { x: 360, y: 196, w: 520, z: -30, rot: [2, 14, 0], breathe: [8, 0.0], bezel: 10, glow: 0.7 }),
    LIFT(1, pad(BOXES.drill.vault, 22, 12), n, { lift: 110 }),
  ]),
  'drill-phone': PHONE(420, (n) => [
    W('drill', n, { x: 188, y: 210, w: 318, z: -30, rot: [2, 10, 0], breathe: [8, 0.0], glow: 0.7 }),
    LIFT(0, pad(BOXES.drill.vault, 22, 12), n, { lift: 80 }),
  ]),

  // ---------- 3. one incident, one push ----------
  alerts: PANEL(400, (n) => [
    W('notify', n, { x: 318, y: 196, w: 480, z: -70, rot: [2, 16, 0], breathe: [8, 0.0], bezel: 10 }),
    W('phone', n, { x: 640, y: 206, w: 236, z: 70, rot: [0, -14, 0], breathe: [8, 0.45], bezel: 10, glowColor: '#3a2420' }),
    LIFT(0, pad(BOXES.notify.sup, 22, 12), n, { lift: 100 }),
  ]),
  'alerts-phone': PHONE(520, (n) => [
    W('notify', n, { x: 176, y: 150, w: 330, z: -70, rot: [2, 12, 0], breathe: [8, 0.0] }),
    W('phone', n, { x: 214, y: 352, w: 236, z: 70, rot: [0, -12, 0], breathe: [8, 0.45], glowColor: '#3a2420' }),
  ]),

  // ---------- 4. the repo is the machine ----------
  drift: PANEL(420, (n) => [
    W('drift', n, { x: 196, y: 196, w: 300, z: -260, rot: [2, 26, 0], ...MID(n), breathe: [8, 0.7] }),
    W('apply', n, { x: 448, y: 206, w: 430, z: -20, rot: [2, 6, 0], breathe: [8, 0.0], bezel: 10 }),
    W('clean', n, { x: 690, y: 286, w: 230, z: 110, rot: [0, -16, 0], breathe: [8, 0.45] }),
    LIFT(1, pad(BOXES.apply.change, 22, 12), n, { lift: 110 }),
  ]),
  'drift-phone': PHONE(480, (n) => [
    W('apply', n, { x: 184, y: 190, w: 330, z: -20, rot: [2, 10, 0], breathe: [8, 0.0] }),
    W('clean', n, { x: 236, y: 380, w: 230, z: 110, rot: [0, -12, 0], breathe: [8, 0.45] }),
    LIFT(0, pad(BOXES.apply.change, 22, 12), n, { lift: 100 }),
  ]),

  // ---------- 5. an operator under a charter ----------
  operator: PANEL(450, (n) => [
    W('charter', n, { x: 356, y: 214, w: 570, z: -40, rot: [2, 10, 0], breathe: [8, 0.0], bezel: 10 }),
    W('wake', n, { x: 690, y: 176, w: 270, z: -200, rot: [2, -26, 0], breathe: [8, 0.45], ...MID(n) }),
    LIFT(0, [BOXES.charter.stop[0] - 22, BOXES.charter.stop[1] + 3, BOXES.charter.stop[2] + 44, BOXES.charter.stop[3] + 8], n, { lift: 120 }),
  ]),
  'operator-phone': PHONE(560, (n) => [
    W('charter', n, { x: 186, y: 170, w: 340, z: -40, rot: [2, 10, 0], breathe: [8, 0.0] }),
    W('wake', n, { x: 206, y: 400, w: 300, z: 60, rot: [0, -10, 0], breathe: [8, 0.45] }),
  ]),

  // ---------- how it works: the front door and everything around it ----------
  topology: PANEL(470, (n) => [
    W('topology', n, { x: 420, y: 232, w: 720, z: -30, rot: [8, 0, 0], breathe: [6, 0.0], bezel: 10, glow: 0.5 }),
    LIFT(0, pad(BOXES.topology.inet, 10, 10), n, { lift: 110, radius: 16, glowColor: '#4a1f1a' }),
  ], { pool: [0.5, 0.5, 0.80, 0.90] }),
  'topology-phone': PHONE(600, (n) => [
    W('topology-phone', n, { x: 190.5, y: 300, w: 330, z: -30, rot: [5, 0, 0], breathe: [6, 0.0], bezel: 8, glow: 0.5 }),
  ]),

  // ---------- the social preview, 1280 x 640 ----------
  social: {
    css: [640, 320], fade: [26, 26, 22, 26], cam: [0, 0], motion: 0, pool: [0.70, 0.52, 0.40, 0.75], night: NIGHT, day: DAY,
    windows: (n) => [
      W('drill', n, { x: 462, y: 128, w: 262, z: -80, rot: [2, -18, 0], breathe: [0, 0], bezel: 9 }),
      W('backup', n, { x: 520, y: 232, w: 196, z: 10, rot: [0, -12, 0], breathe: [0, 0], bezel: 8 }),
      LIFT(0, pad(BOXES.drill.sum, 22, 12), n, { lift: 120, breathe: [0, 0] }),
    ],
    type: [
      T('kick', 'Infrastructure · Shell', 40, 104, { fontSize: '10px' }),
      T('name', 'homelab', 38, 122, { fontSize: '46px' }),
      T('line', 'Fifteen services on a<br>Raspberry Pi 5, managed<br>as code, with backups<br>that prove themselves.', 40, 182, { fontSize: '15.5px' }),
    ],
  },
};
for (const k in LAYOUTS) LAYOUTS[k].dpr = LAYOUTS[k].dpr || 2;
