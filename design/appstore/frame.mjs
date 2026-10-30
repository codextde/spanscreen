import { chromium } from '/Users/danielehrhardt/node_modules/playwright-core/index.mjs';
const exe = process.env.HOME + '/Library/Caches/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell';
const titles = {
  'en-US': ['Your iPhone, now a <span>second Mac display</span>', 'Extend or mirror. <span>Wi-Fi or USB.</span>', 'Connects in <span>seconds</span>', 'Only the Macs <span>you allow</span>'],
  'de-DE': ['Dein iPhone als <span>zweiter Mac-Bildschirm</span>', 'Erweitern oder spiegeln. <span>WLAN oder USB.</span>', 'In Sekunden <span>verbunden</span>', 'Nur Macs, die <span>du erlaubst</span>'],
};
const sets = { pm: { w: 2868, h: 1320, files: ['pm-1-stream', 'pm-2-panel', 'pm-3-home', 'pm-4-approval'] }, ipad: { w: 2752, h: 2064, files: ['ipad-1-stream', 'ipad-2-panel', 'ipad-3-home', 'ipad-4-approval'] }, duo: { w: 2034, h: 1398, files: ['1-stream', '2-panel', '3-home', '4-approval'], localized: true } };
const only = process.argv[2];
const b = await chromium.launch({ executablePath: exe });
for (const [kind, set] of Object.entries(sets)) {
  if (only && kind !== only) continue;
  const p = await b.newPage({ viewport: { width: set.w / 2, height: set.h / 2 }, deviceScaleFactor: 2 });
  for (const [locale, list] of Object.entries(titles)) {
    for (let i = 0; i < set.files.length; i++) {
      const src = `file://${process.cwd()}/${set.localized ? `${kind}/${locale.slice(0, 2)}-` : ''}${set.files[i]}.png`;
      const title = kind === 'ipad' ? list[i].replace('iPhone', 'iPad') : kind === 'duo' ? list[i].replace('iPhone', 'iPhone Duo') : list[i];
      const url = `file://${process.cwd()}/frame.html?kind=${kind}&sw=${set.w}&sh=${set.h}&src=${encodeURIComponent(src)}&title=${encodeURIComponent(title)}`;
      await p.goto(url); await p.waitForTimeout(250);
      await p.screenshot({ path: `framed/${locale}-${kind}-${i + 1}.png` });
    }
  }
}
await b.close();
