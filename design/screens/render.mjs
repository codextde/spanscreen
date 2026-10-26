import { chromium } from '/Users/danielehrhardt/node_modules/playwright-core/index.mjs';
const exe = process.env.HOME + '/Library/Caches/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell';
const [w, h, out] = process.argv.slice(2);
const b = await chromium.launch({ executablePath: exe });
const p = await b.newPage({ viewport: { width: +w / 2, height: +h / 2 }, deviceScaleFactor: 2 });
await p.goto(`file://${process.cwd()}/desktop.html?w=${w/2}&h=${h/2}`);
await p.waitForTimeout(300);
await p.screenshot({ path: out });
await b.close();
