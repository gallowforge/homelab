// Renders Glass scenes with headless Chromium (GPU on) through Playwright.
//   node render.cjs <layout>,<dark|light>,still,<phase>,<out.png> [more jobs...]
//   node render.cjs <layout>,<dark|light>,anim,<frames>,<outDir> [more jobs...]
// Serves docs/readme/src as the page root: glass/scene.html, layouts.js, shots/*.png and three.js
// from wherever Node resolves it (NODE_PATH). Needs the `playwright` and `three` packages.
const { chromium } = require('playwright');
const path = require('path'), fs = require('fs'), { pathToFileURL } = require('url');
const ROOT = path.resolve(__dirname, '..');
const THREE_DIR = path.resolve(path.dirname(require.resolve('three')), '..');   // three/build/three.cjs
const MIME = { '.js': 'text/javascript', '.html': 'text/html', '.png': 'image/png', '.json': 'application/json', '.css': 'text/css' };
(async () => {
  const { LAYOUTS } = await import(pathToFileURL(path.join(ROOT, 'layouts.js')).href);
  const jobs = process.argv.slice(2).map(j => j.split(','));
  const browser = await chromium.launch({ args: ['--use-angle=vulkan', '--enable-features=Vulkan', '--ignore-gpu-blocklist', '--enable-gpu'] });
  for (const [layout, theme, mode, arg, out] of jobs) {
    const L = LAYOUTS[layout];
    if (!L) throw new Error('no layout ' + layout);
    const ctx = await browser.newContext({ viewport: { width: L.css[0], height: L.css[1] }, deviceScaleFactor: L.dpr });
    const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error') console.log('[page]', m.text().slice(0, 2000)); });
    page.on('pageerror', e => console.log('[pageerror]', e.message));
    await page.route('http://glass.local/**', r => {
      const u = decodeURIComponent(new URL(r.request().url()).pathname);
      const f = u.startsWith('/node_modules/three/') ? path.join(THREE_DIR, u.slice('/node_modules/three/'.length)) : path.join(ROOT, u);
      if (fs.existsSync(f)) r.fulfill({ path: f, contentType: MIME[path.extname(f)] || 'application/octet-stream' });
      else { console.log('404', u); r.fulfill({ status: 404, body: '' }); }
    });
    await page.goto(`http://glass.local/glass/scene.html?layout=${layout}&theme=${theme}&ss=2`);
    await page.waitForFunction(() => window.__ready !== undefined, null, { timeout: 30000 });
    await page.evaluate(() => window.__ready);
    await page.waitForTimeout(250);
    const t0 = Date.now();
    if (mode === 'still') {
      await page.evaluate(p => window.renderAt(p), +arg);
      await page.screenshot({ path: out });
    } else {
      const n = +arg; fs.mkdirSync(out, { recursive: true });
      for (let i = 0; i < n; i++) {
        await page.evaluate(p => window.renderAt(p), i / n);
        await page.screenshot({ path: path.join(out, `f${String(i).padStart(4, '0')}.png`) });
      }
    }
    console.log(`${layout} ${theme} ${mode} ${((Date.now() - t0) / 1000).toFixed(1)}s`);
    await ctx.close();
  }
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
