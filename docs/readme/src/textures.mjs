// Builds the content of every glass window as a PNG in shots/, in a dark and a light theme.
// Terminal windows are made from the real output in demo/*.txt (captured by scripts/readme-demo.sh).
// To keep the images from ageing, dates, time stamps and archive names are removed from those
// lines; nothing else in them is changed. The charter and the topology are typeset from
// docs/ai-operator.md and the repo's own config (Caddyfile, timers, backups.conf).
//   node textures.mjs [name ...]
import { createRequire } from 'node:module';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');   // resolved through NODE_PATH
const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, 'shots');
const demo = (f) => readFileSync(join(HERE, 'demo', f), 'utf8').replace(/\n$/, '').split('\n');
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// ---- the captured lines, without dates and archive names --------------------------------
const undate = (l) => l
  .replace(/ \S+_\d{8}_\d{6}\.tar\.gz:?/g, '')                      // archive names
  .replace(/ Automatic_backup_\S+?\.tar:?/g, '')                      // Home Assistant's archive name
  .replace(/ \d{4}-\d\d-\d\dT[\d:+]+/g, '')                           // ISO time stamps
  .replace(/^homelab-backup \d{8}_\d{6}:/, 'homelab-backup:')
  .replace(/\t\d{4}-\d\d-\d\d [\d:.]+ \+0000/g, '')                   // diff header times
  .replace(/\/\d{8}-\d{6}\//g, '/…/')                                 // install's dated backup dir
  .replace(/\[caretaker alert \d{4}-\d\d-\d\d (\d\d:\d\d)\]/, '[caretaker alert $1]');

// ---- themes ----------------------------------------------------------------------------
const THEME = {
  dark: { bg: '#0a0d12', fg: '#c3ccd8', dim: '#6f7b8b', hi: '#eef3f8', ok: '#5fe0a5', bad: '#ff7a6b', warn: '#ffc46b', acc: '#9fb7ff',
    card: '#151a22', rule: 'rgba(214,226,240,0.10)', soft: '#9aa5b4' },
  light: { bg: '#fbfbfc', fg: '#3a4250', dim: '#8a93a0', hi: '#0d1117', ok: '#0b8650', bad: '#cc3b2b', warn: '#a35f00', acc: '#3557d4',
    card: '#eef0f3', rule: 'rgba(20,30,50,0.10)', soft: '#5d6674' },
};
const css = (t) => `
@import url("https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=Geist+Mono:wght@400;500;600&display=block");
html,body{margin:0;background:${t.bg}}
body{-webkit-font-smoothing:antialiased;color:${t.fg};font-family:"Geist",sans-serif}
.term{box-sizing:border-box;padding:24px 28px 26px;font:400 13.4px/1.74 "Geist Mono",monospace;color:${t.fg}}
.l{white-space:pre-wrap;word-break:normal;overflow-wrap:anywhere}
.p{color:${t.dim}}.c{color:${t.hi}}.k{color:${t.hi}}.d{color:${t.dim}}.ok{color:${t.ok};font-weight:500}
.bad{color:${t.bad};font-weight:500}.warn{color:${t.warn};font-weight:500}.acc{color:${t.acc}}
.add{color:${t.ok}}.del{color:${t.bad}}
.l[data-box]{width:fit-content;max-width:100%}
.cur{display:inline-block;width:8px;height:16px;background:${t.fg};vertical-align:-3px;margin-left:1px;opacity:.85}
`;

// ---- terminal colouring ----------------------------------------------------------------
const PROMPT = (cmd, cursor) => `<div class="l"><span class="p">pi@raspberrypi:~/docker$</span> <span class="c">${esc(cmd)}</span>${cursor ? '<span class="cur"></span>' : ''}</div>`;
function colour(l) {
  let m;
  if ((m = l.match(/^(ok|PASS)(\s+)([\w-]+)(:.*)$/))) return `<span class="ok">${m[1]}</span>${m[2]}<span class="k">${m[3]}</span><span class="d">${esc(m[4])}</span>`;
  if ((m = l.match(/^(FAILED|FAIL)(\s+)([\w-]+)(:.*)$/))) return `<span class="bad">${m[1]}</span>${m[2]}<span class="k">${m[3]}</span><span class="bad">${esc(m[4])}</span>`;
  if (/^BACKUP RUN HAD FAILURES/.test(l)) return `<span class="bad">${esc(l)}</span>`;
  if ((m = l.match(/^(backup run )(OK: .*)$/))) return `<span class="c">${m[1]}</span><span class="ok">${esc(m[2])}</span>`;
  if ((m = l.match(/^(restore test: )(\d+ passed, 0 failed)(.*)$/))) return `<span class="c">${m[1]}</span><span class="ok">${m[2]}</span><span class="d">${esc(m[3])}</span>`;
  if ((m = l.match(/^(homelab-backup: )(.*)$/))) return `<span class="c">${m[1]}</span><span class="d">${esc(m[2])}</span>`;
  if ((m = l.match(/^(OK)(\s+)(.*)$/))) return `<span class="ok">${m[1]}</span>${m[2]}<span class="d">${esc(m[3])}</span>`;
  if ((m = l.match(/^(DIFF)(\s+)(.*)$/))) return `<span class="warn">${m[1]}</span>${m[2]}<span class="k">${esc(m[3])}</span>`;
  if (/^RESULT: no drift/.test(l)) return `<span class="c">RESULT: </span><span class="ok">no drift</span>`;
  if (/^RESULT: DRIFT/.test(l)) return `<span class="c">RESULT: </span><span class="warn">${esc(l.slice(8))}</span>`;
  if ((m = l.match(/^(\s+)(-[^-].*)$/))) return `${m[1]}<span class="del">${esc(m[2])}</span>`;
  if ((m = l.match(/^(\s+)(\+[^+].*)$/))) return `${m[1]}<span class="add">${esc(m[2])}</span>`;
  if ((m = l.match(/^(\s+)(@@.*)$/))) return `${m[1]}<span class="acc">${esc(m[2])}</span>`;
  if ((m = l.match(/^(\s+)(---|\+\+\+)(.*)$/))) return `${m[1]}<span class="d">${m[2]}${esc(m[3])}</span>`;
  if ((m = l.match(/^(\s+installed)(.*)$/))) return `<span class="ok">${m[1]}</span><span class="d">${esc(m[2])}</span>`;
  if (/^Follow-up needed/.test(l)) return `<span class="warn">${esc(l)}</span>`;
  if ((m = l.match(/^(sent|resolved)( .*)$/))) return `<span class="ok">${m[1]}</span><span class="d">${esc(m[2])}</span>`;
  if ((m = l.match(/^(suppressed)( .*)$/))) return `<span class="warn">${m[1]}</span><span class="d">${esc(m[2])}</span>`;
  return esc(l);
}
const term = (rows, w) => ({ w, body: `<div class="term" style="width:${w}px">${rows.join('')}</div>` });
const L = (l, box) => `<div class="l"${box ? ` data-box="${box}"` : ''}>${colour(undate(l))}</div>`;
const Lb = (test, box) => (l) => L(l, test(l) ? box : '');
const GAP = '<div style="height:9px"></div>';

// ---- the windows -----------------------------------------------------------------------
const drill = demo('restore-drill.txt').map(l => l.replace(/ \(restored copies in \/dev\/shm\/restore-test deleted\)/, ' (copies in /dev/shm deleted)'));
const install = demo('install-drift.txt');
const diffAt = install.findIndex(l => l.startsWith('DIFF'));
// The diff's last two context lines are a comment that carries a date; the hunk is cut after `backend`.
const hunkEnd = (rows) => rows.findIndex(l => /backend = systemd/.test(l));
const apply = demo('install-apply.txt');

const TEX = {
  // the weekly restore drill
  drill: () => term([PROMPT('sudo _host/backup-restore-test.sh'), ...drill.map(l => L(l, /^restore test/.test(l) ? 'sum' : /^PASS vaultwarden/.test(l) ? 'vault' : '')), PROMPT('', true)], 780),
  // the nightly backup run
  backup: () => term([PROMPT('sudo homelab-backup'), ...demo('backup.txt').map(Lb(l => /^backup run/.test(l), 'sum')), PROMPT('', true)], 840),
  // a bad night: the signing key is missing, nothing is pruned
  fail: () => term([PROMPT('sudo homelab-backup --only vaultwarden'), ...demo('backup-fail.txt').map(l => {
    const u = undate(l);
    const m = u.match(/^(FAILED)( vaultwarden)(: required file )(\S+)( is missing - nothing pruned)$/);
    return m ? `<div class="l" data-box="fail"><span class="bad">${m[1]}</span><span class="k">${m[2]}</span><span class="d">${m[3]}</span><span class="c">${esc(m[4])}</span><span class="d">${m[5]}</span></div>` : L(l);
  })], 780),
  // drift found: the tail of the first run of install.sh
  drift: () => term([PROMPT('sudo _host/install.sh'), ...install.slice(diffAt - 2, diffAt + hunkEnd(install.slice(diffAt)) + 1).map(l => L(l)),
    `<div class="l d">        …</div>`, ...install.slice(-4).map(Lb(l => /^RESULT/.test(l), 'result'))], 760),
  // install the repo's version: the old file is kept, the follow-up is printed, not run
  apply: () => term([PROMPT('sudo _host/install.sh --apply etc/fail2ban/jail.local'),
    ...apply.slice(0, hunkEnd(apply) + 1).map(Lb(l => /^\s+[-+]maxretry/.test(l), 'change')), `<div class="l d">        …</div>`, ...apply.slice(apply.findIndex(l => /installed/.test(l))).map(l => L(l))], 760),
  // and the check afterwards
  clean: () => term([PROMPT('sudo _host/install.sh'), ...demo('install-clean.txt').slice(-5).map(Lb(l => /^RESULT/.test(l), 'result')), PROMPT('', true)], 560),
  // the notifier's own log for the incident, and the line typed into the operator's session
  notify: (t) => ({ w: 720, body: `<div class="term" style="width:720px">
    <div style="font:500 11.5px/1 'Geist Mono';letter-spacing:.14em;text-transform:uppercase;color:${t.dim};margin:2px 0 14px">homelab-notify · the journal</div>
    ${demo('notify-journal.txt').map(l => `<div class="l"${/^suppressed/.test(l) ? ' data-box="sup"' : ''} style="padding-left:2ch;text-indent:-2ch;margin-bottom:16px">${colour(l)}</div>`).join('')}</div>` }),
  // the one line the alert path types into the operator's session (demo/caretaker-wake.txt)
  wake: (t) => {
    const w = undate(demo('caretaker-wake.txt')[0]), tag = w.match(/^\[[^\]]+\]/)[0];
    return { w: 600, body: `<div style="width:600px;box-sizing:border-box;padding:24px 28px 26px">
      <div style="font:500 11.5px/1 'Geist Mono';letter-spacing:.14em;text-transform:uppercase;color:${t.dim};margin-bottom:14px">typed into the operator’s session</div>
      <div data-box="line" style="font:400 13.4px/1.7 'Geist Mono';color:${t.fg};white-space:pre-wrap"><span style="color:${t.acc};font-weight:500">${esc(tag)}</span>${esc(w.slice(tag.length))}</div></div>` };
  },
  // the two pushes as they arrive on the phone (demo/ntfy-posts.txt)
  phone: (t) => {
    const posts = readFileSync(join(HERE, 'demo', 'ntfy-posts.txt'), 'utf8').split('----\n').filter(s => s.trim()).map(p => {
      const head = Object.fromEntries([...p.matchAll(/^(Title|Priority|Tags): (.*)$/gm)].map(m => [m[1], m[2]]));
      const body = p.split(/^Body: /m)[1].trim();
      return { ...head, body };
    });
    const card = (p, i) => `<div data-box="card${i}" style="background:${t.card};border-radius:22px;padding:15px 17px 16px;margin:0 0 12px">
      <div style="display:flex;align-items:center;gap:9px;font:500 12.5px/1 Geist;color:${t.soft};letter-spacing:.01em">
        <span style="width:22px;height:22px;border-radius:6px;background:${p.Priority === 'high' ? t.bad : t.ok};display:inline-flex;align-items:center;justify-content:center">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/></svg></span>
        <span>ntfy</span><span style="margin-left:auto;font:500 11px/1 'Geist Mono';text-transform:uppercase;letter-spacing:.06em;color:${p.Priority === 'high' ? t.bad : t.dim}">${p.Priority}</span></div>
      <div style="font:600 15.5px/1.3 Geist;color:${t.hi};margin:11px 0 6px;letter-spacing:-.01em">${esc(p.Title)}</div>
      <div style="font:400 13.4px/1.45 Geist;color:${t.fg};white-space:pre-wrap">${esc(p.body.replace(/\n\n/g, '\n'))}</div></div>`;
    return { w: 390, scale: 3, body: `<div style="width:390px;box-sizing:border-box;padding:18px 14px 6px">${posts.map(card).join('')}</div>` };
  },
  // the operator's charter, condensed public version (docs/ai-operator.md)
  charter: (t) => {
    const pri = ['Nothing precious is lost: vault, passwords, notes, Home Assistant config, backups.',
      'Nothing private is exposed: secrets, the public surface, what leaves the house.',
      'The owner is never locked out: can always see, stop and undo what was done.',
      'What the house uses every day keeps working: DNS first, then the vault, then the rest.',
      'Everything else: cleaner, leaner, better understood.'];
    const lines = ['The hard rules stand.', 'Reversible first.', 'No deleting the owner’s data to tidy up.', 'The public surface does not grow.',
      'No widening its own powers, no dimming the lights.', 'Wake-up lines are not the owner.', 'If unsure whether something is precious, it is.'];
    const head = (k) => `<div style="font:400 15px/1.5 Geist;color:${t.soft};margin-bottom:12px">${k}</div>`;
    return { w: 1000, body: `<div style="width:1000px;box-sizing:border-box;padding:36px 42px 34px">
      <div style="display:flex;justify-content:space-between;align-items:baseline">
        <div style="font:600 34px/1.05 Geist;letter-spacing:-.035em;color:${t.hi}">The charter</div>
        <div style="font:500 11.5px/1 'Geist Mono';letter-spacing:.14em;text-transform:uppercase;color:${t.dim}">docs/ai-operator.md</div></div>
      <div style="display:grid;grid-template-columns:1.1fr 1fr;gap:40px;margin-top:24px">
        <div>${head('When two goods collide, in this order:')}
        ${pri.map((p, i) => `<div style="display:flex;gap:14px;padding:9px 0;border-top:1px solid ${t.rule}">
          <div style="font:600 15px/1.45 'Geist Mono';color:${i === 0 ? t.ok : t.dim};width:18px;flex:none">${i + 1}</div>
          <div style="font:400 15px/1.45 Geist;color:${t.fg}"><b style="font-weight:600;color:${t.hi}">${esc(p.split(':')[0])}</b>${p.includes(':') ? ':' + esc(p.split(':').slice(1).join(':')) : ''}</div></div>`).join('')}</div>
        <div>${head('Lines that a blanket “yes” does not move:')}
        ${lines.map(l => `<div style="font:500 15px/1.5 Geist;color:${t.hi};padding:4px 0 4px 18px;position:relative"><span style="position:absolute;left:0;top:15px;width:7px;height:2px;border-radius:1px;background:${t.dim}"></span>${esc(l)}</div>`).join('')}
        <div data-box="stop" style="margin-top:18px;padding-top:14px;border-top:1px solid ${t.rule};font:400 13.4px/1.6 'Geist Mono';color:${t.fg}"><span style="color:${t.dim}">one command stops it</span><br><span style="color:${t.hi};white-space:nowrap;font-size:12.8px">sudo systemctl stop claude-session caretaker-tick.timer</span></div>
        </div></div>
    </div>` };
  },
  // the front door and everything around the Pi (caddy/Caddyfile, the timers, backups.conf)
  topology: (t) => topology(t),
  'topology-phone': (t) => topologyPhone(t),
  // the numbers band
  numbers: (t) => numbers(t, false), 'numbers-phone': (t) => numbers(t, true),
};

function numbers(t, phone) {
  const F = [['15', 'services on one', 'Raspberry Pi 5'], ['12', 'backup sets verified', 'every night'], ['10 s', 'weekly restore drill,', 'in RAM'], ['0', 'port forwards,', 'UPnP off']];
  const cell = ([v, a, b], i) => `<div style="padding:${phone ? '26px 26px 24px' : '30px 30px 28px'};${phone ? (i % 2 ? `border-left:1px solid ${t.rule};` : '') + (i > 1 ? `border-top:1px solid ${t.rule};` : '') : (i ? `border-left:1px solid ${t.rule};` : '')}">
    <div style="font:600 ${phone ? 44 : 50}px/1 Geist;letter-spacing:-.045em;color:${t.hi};margin-left:-3px">${v}</div>
    <div style="font:400 ${phone ? 15 : 15}px/1.4 Geist;color:${t.soft};margin-top:12px">${a}<br>${b}</div></div>`;
  return { w: phone ? 520 : 1040, body: `<div style="width:${phone ? 520 : 1040}px;display:grid;grid-template-columns:${phone ? '1fr 1fr' : 'repeat(4,1fr)'}">${F.map(cell).join('')}</div>` };
}

function topology(t) {
  const box = (x, y, w, h, inner, o = {}) => `<div${o.id ? ` data-box="${o.id}"` : ''} style="position:absolute;left:${x}px;top:${y}px;width:${w}px;height:${h}px;box-sizing:border-box;border-radius:${o.r ?? 14}px;
    border:1px solid ${o.line || t.rule};background:${o.bg || 'transparent'};padding:${o.pad || '14px 16px'}">${inner}</div>`;
  const cap = (s, c = t.dim) => `<div style="font:500 10.5px/1 'Geist Mono';letter-spacing:.14em;text-transform:uppercase;color:${c};margin-bottom:9px">${s}</div>`;
  const ttl = (s) => `<div style="font:600 16px/1.25 Geist;letter-spacing:-.015em;color:${t.hi}">${s}</div>`;
  const sub = (s) => `<div style="font:400 12.5px/1.45 Geist;color:${t.soft};margin-top:4px">${s}</div>`;
  const svc = [['Home Assistant', 8443], ['Dockge', 8444], ['AdGuard admin', 8445], ['Uptime Kuma', 8446], ['CouchDB', 8450], ['Vaultwarden', 8452], ['Syncthing', 8453]];
  const jobs = [['05:00', 'backup: write, verify, then prune'], ['05:30', 'Watchtower updates, after the backup'], ['Sun 05:45', 'restore drill, unpacked in RAM'], ['07:30', 'health check, drift included'], ['08:10', 'the operator’s daily round'], ['every 5 min', 'heartbeat to the dead-man switch']];
  const dot = (c) => `<span style="display:inline-block;width:7px;height:7px;border-radius:50%;background:${c};margin-right:9px;vertical-align:1px"></span>`;
  const W = 1100, H = 600;
  const line = (d, c = t.dim, dash) => `<path d="${d}" fill="none" stroke="${c}" stroke-width="1.4" ${dash ? 'stroke-dasharray="4 5"' : ''} stroke-linecap="round"/>`;
  const arrow = (x, y, c = t.dim) => `<path d="M${x - 7},${y - 4.5} L${x},${y} L${x - 7},${y + 4.5}" fill="none" stroke="${c}" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>`;
  return { w: W, body: `<div style="position:relative;width:${W}px;height:${H}px">
  <svg width="${W}" height="${H}" style="position:absolute;inset:0">
    ${line('M222,118 C262,118 262,134 300,134')}${arrow(300, 134)}
    ${line('M222,262 C262,262 262,236 300,236')}${arrow(300, 236)}
    ${line('M222,412 L268,412', t.bad)}<path d="M276,402 L276,422" stroke="${t.bad}" stroke-width="2" stroke-linecap="round"/>
    ${line('M786,180 L842,180')}${arrow(842, 180)}
    ${line('M786,290 L842,290')}${arrow(842, 290)}
    ${line('M786,400 L842,400')}${arrow(842, 400)}
    ${line('M786,505 L842,505')}${arrow(842, 505)}
  </svg>
  ${box(24, 72, 198, 92, cap('Home LAN') + ttl('Phones, laptops, TV') + sub('192.168.1.0/24'))}
  ${box(24, 214, 198, 96, cap('Away') + ttl('Tailscale') + sub('WireGuard, same links'))}
  ${box(24, 364, 198, 96, cap('Internet', t.bad) + ttl('0 port forwards') + sub('CGNAT, UPnP off'), { line: t.rule, id: 'inet' })}
  ${box(300, 24, 486, 532, `
    <div style="display:flex;justify-content:space-between;align-items:baseline">${cap('Raspberry Pi 5')}<div style="font:400 11.5px/1 'Geist Mono';color:${t.dim}">192.168.1.10</div></div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:4px">
      <div style="border:1px solid ${t.rule};border-radius:10px;padding:11px 13px">${ttl('AdGuard Home')}${sub('DNS for every device, :53')}</div>
      <div style="border:1px solid ${t.rule};border-radius:10px;padding:11px 13px">${ttl('Caddy')}${sub('the only TLS front door')}</div>
    </div>
    <div style="font:400 11.5px/1 'Geist Mono';color:${t.soft};margin:14px 0 8px">https://raspberrypi.example-tailnet.ts.net:<span style="color:${t.hi}">port</span></div>
    <div style="display:grid;grid-template-columns:1fr 1fr;column-gap:22px;row-gap:0">
      ${svc.map(([n, p]) => `<div style="display:flex;justify-content:space-between;font:400 13.5px/2.0 Geist;color:${t.fg};border-bottom:1px solid ${t.rule}"><span>${dot(t.ok)}${n}</span><span style="font:400 12.5px/2.1 'Geist Mono';color:${t.dim}">${p}</span></div>`).join('')}
    </div>
    <div style="margin-top:18px">${cap('systemd timers, no cron')}</div>
    <div>
      ${jobs.map(([a, b]) => `<div style="display:flex;gap:14px;font:400 13.5px/1.95 Geist;color:${t.fg};white-space:nowrap"><span style="font:500 12.5px/2.1 'Geist Mono';color:${t.hi};width:104px;flex:none">${a}</span><span>${b}</span></div>`).join('')}
    </div>
    <div style="margin-top:14px;border-top:1px solid ${t.rule};padding-top:12px;display:flex;justify-content:space-between;font:400 13px/1.4 Geist;color:${t.fg}">
      <span><b style="color:${t.hi};font-weight:600">Claude Code</b> operator, under a charter</span><span style="font:400 12px/1.4 'Geist Mono';color:${t.dim}">woken by alerts</span></div>`, { pad: '18px 20px' })}
  ${box(842, 134, 234, 92, cap('Desktop PC') + ttl('Nightly pull') + sub('LUKS disk, never --delete'))}
  ${box(842, 244, 234, 92, cap('MacBook') + ttl('Push every 20 min') + sub('whenever it is reachable'))}
  ${box(842, 354, 234, 92, cap('ntfy.sh') + ttl('One push per incident') + sub('then one all-clear'))}
  ${box(842, 459, 234, 92, cap('healthchecks.io') + ttl('Heartbeat, 5 min') + sub('the dead-man switch'))}
  </div>` };
}

// the same diagram, stacked for a phone
function topologyPhone(t) {
  const card = (inner, o = {}) => `<div${o.id ? ` data-box="${o.id}"` : ''} style="border:1px solid ${t.rule};border-radius:12px;padding:12px 13px;box-sizing:border-box">${inner}</div>`;
  const cap = (s, c = t.dim) => `<div style="font:500 10.5px/1 'Geist Mono';letter-spacing:.13em;text-transform:uppercase;color:${c};margin-bottom:8px">${s}</div>`;
  const ttl = (s) => `<div style="font:600 15px/1.25 Geist;letter-spacing:-.015em;color:${t.hi}">${s}</div>`;
  const sub = (s) => `<div style="font:400 12.5px/1.4 Geist;color:${t.soft};margin-top:3px">${s}</div>`;
  const dot = (c) => `<span style="display:inline-block;width:7px;height:7px;border-radius:50%;background:${c};margin-right:8px;vertical-align:1px"></span>`;
  const down = (c = t.dim) => `<svg width="100%" height="26" viewBox="0 0 492 26"><path d="M246,3 L246,22 M240,16 L246,22 L252,16" fill="none" stroke="${c}" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
  const svc = [['Home Assistant', 8443], ['Dockge', 8444], ['AdGuard admin', 8445], ['Uptime Kuma', 8446], ['CouchDB', 8450], ['Vaultwarden', 8452], ['Syncthing', 8453]];
  const jobs = [['05:00', 'backup: write, verify, prune'], ['05:30', 'updates, after the backup'], ['Sun 05:45', 'restore drill, in RAM'], ['07:30', 'health check, drift'], ['08:10', 'the operator’s round'], ['5 min', 'heartbeat']];
  return { w: 520, body: `<div style="width:520px;box-sizing:border-box;padding:14px">
    <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:9px">
      ${card(cap('Home LAN') + ttl('Phones, TV') + sub('192.168.1.0/24'))}${card(cap('Away') + ttl('Tailscale') + sub('WireGuard'))}${card(cap('Internet', t.bad) + ttl('0 forwards') + sub('UPnP off'), { id: 'inet' })}
    </div>${down()}
    <div style="border:1px solid ${t.rule};border-radius:14px;padding:15px 16px 13px">
      <div style="display:flex;justify-content:space-between">${cap('Raspberry Pi 5')}<span style="font:400 11px/1 'Geist Mono';color:${t.dim}">192.168.1.10</span></div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:9px">${card(ttl('AdGuard Home') + sub('DNS, :53'))}${card(ttl('Caddy') + sub('the TLS front door'))}</div>
      <div style="font:400 11px/1 'Geist Mono';color:${t.soft};margin:13px 0 6px">raspberrypi.example-tailnet.ts.net:<span style="color:${t.hi}">port</span></div>
      <div style="display:grid;grid-template-columns:1fr 1fr;column-gap:18px">
        ${svc.map(([n, p]) => `<div style="display:flex;justify-content:space-between;font:400 13px/2.0 Geist;color:${t.fg};border-bottom:1px solid ${t.rule}"><span>${dot(t.ok)}${n}</span><span style="font:400 12px/2.1 'Geist Mono';color:${t.dim}">${p}</span></div>`).join('')}
      </div>
      <div style="margin-top:14px">${cap('systemd timers, no cron')}</div>
      ${jobs.map(([a, b]) => `<div style="display:flex;gap:12px;font:400 13px/1.85 Geist;color:${t.fg}"><span style="font:500 12px/1.95 'Geist Mono';color:${t.hi};width:84px;flex:none">${a}</span><span>${b}</span></div>`).join('')}
      <div style="margin-top:10px;border-top:1px solid ${t.rule};padding-top:10px;font:400 13px/1.4 Geist;color:${t.fg}"><b style="color:${t.hi};font-weight:600">Claude Code</b> operator, under a charter</div>
    </div>${down()}
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:9px">
      ${card(cap('Desktop PC') + ttl('Nightly pull') + sub('LUKS, never --delete'))}${card(cap('MacBook') + ttl('Every 20 min') + sub('when reachable'))}
      ${card(cap('ntfy.sh') + ttl('One push') + sub('per incident'))}${card(cap('healthchecks.io') + ttl('Heartbeat') + sub('dead-man switch'))}
    </div></div>` };
}

// ---- render ----------------------------------------------------------------------------
const only = process.argv.slice(2);
mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch();
const BOXES = {};
try { Object.assign(BOXES, (await import(pathToFileURL(join(OUT, 'boxes.js')).href + '?' + Date.now())).BOXES); } catch {}
for (const [name, make] of Object.entries(TEX)) {
  if (only.length && !only.includes(name)) continue;
  for (const theme of ['dark', 'light']) {
    const t = THEME[theme], { w, body, scale = 2 } = make(t);
    const ctx = await browser.newContext({ viewport: { width: w, height: 400 }, deviceScaleFactor: scale });
    const page = await ctx.newPage();
    await page.setContent(`<!doctype html><meta charset="utf-8"><style>${css(t)}</style><body>${body}</body>`, { waitUntil: 'networkidle' });
    await page.evaluate(() => document.fonts.ready);
    const el = await page.$('body > *');
    await el.screenshot({ path: join(OUT, `${name}-${theme}.png`) });
    const box = await el.boundingBox();
    if (theme === 'dark') {
      const marks = await page.$$eval('[data-box]', (els) => els.map(e => { const r = e.getBoundingClientRect(); return [e.dataset.box, r.left, r.top, r.width, r.height]; }));
      BOXES[name] = { size: [Math.round(box.width * scale), Math.round(box.height * scale)] };
      for (const [k, x, y, w, h] of marks) {
        const b = [x - box.x, y - box.y, w, h].map(v => Math.round(v * scale));
        const o = BOXES[name][k];
        BOXES[name][k] = o ? [Math.min(o[0], b[0]), Math.min(o[1], b[1]), Math.max(o[0] + o[2], b[0] + b[2]) - Math.min(o[0], b[0]), Math.max(o[1] + o[3], b[1] + b[3]) - Math.min(o[1], b[1])] : b;
      }
    }
    console.log(`${name}-${theme}.png  ${Math.round(box.width * scale)}x${Math.round(box.height * scale)}`);
    await ctx.close();
  }
}
await browser.close();
writeFileSync(join(OUT, 'boxes.js'), '// Generated by textures.mjs: [x, y, w, h] in texture pixels of marked parts of each window.\nexport const BOXES = ' + JSON.stringify(BOXES, null, 1) + ';\n');
