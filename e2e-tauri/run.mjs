/**
 * Drives the real Chump (Cowork) Tauri shell via tauri-driver + WebKitWebDriver (Linux).
 * Prereqs: Linux, WebKitWebDriver on PATH, `cargo install tauri-driver --locked`,
 * `target/debug/chump-desktop` + `target/debug/chump`, chump --web already listening
 * (see scripts/ci/run-tauri-e2e.sh).
 */
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Builder, By, Capabilities, until } from 'selenium-webdriver';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const desktopBin = path.join(repoRoot, 'target', 'debug', 'chump-desktop');

const TAURI_DRIVER =
  process.env.TAURI_DRIVER_PATH ||
  path.join(process.env.HOME || process.env.USERPROFILE || '.', '.cargo', 'bin', 'tauri-driver');

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForWebDriverReady(ms = 120_000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    try {
      const r = await fetch('http://127.0.0.1:4444/status');
      if (r.ok) return;
    } catch {
      /* ignore */
    }
    await sleep(200);
  }
  throw new Error('tauri-driver did not become ready on http://127.0.0.1:4444/status');
}

let tauriDriverProc = null;
let exiting = false;

function shutdown() {
  exiting = true;
  if (tauriDriverProc && !tauriDriverProc.killed) {
    try {
      tauriDriverProc.kill('SIGTERM');
    } catch {
      /* ignore */
    }
  }
}

for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => {
    shutdown();
    process.exit(130);
  });
}

tauriDriverProc = spawn(TAURI_DRIVER, [], {
  stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env },
});
tauriDriverProc.stdout?.on('data', (d) => process.stdout.write(d));
tauriDriverProc.stderr?.on('data', (d) => process.stderr.write(d));
tauriDriverProc.on('error', (err) => {
  console.error('tauri-driver spawn failed:', err.message);
  console.error('Install with: cargo install tauri-driver --locked');
  process.exit(1);
});
tauriDriverProc.on('exit', (code, sig) => {
  if (!exiting && code !== 0 && code !== null) {
    console.error('tauri-driver exited unexpectedly:', code, sig);
    process.exit(1);
  }
});

await waitForWebDriverReady();

const caps = new Capabilities();
caps.setBrowserName('wry');
caps.set('tauri:options', { application: path.resolve(desktopBin) });

/** @type {import('selenium-webdriver').WebDriver | undefined} */
let driver;
try {
  driver = await new Builder()
    .usingServer('http://127.0.0.1:4444')
    .withCapabilities(caps)
    .build();

  await driver.manage().setTimeouts({ implicit: 2000, pageLoad: 120_000, script: 60_000 });

  // INFRA-250 (v1 retirement): the PWA is now web/v2, a Web-Components app.
  // The chat surface is `<chump-chat>` — its <input>, <send-btn>, and message
  // bubbles all live INSIDE its shadow root, so plain `By.css(...)` can't reach
  // them. Use shadowRoot.querySelector via executeScript instead.

  // Page-load smoke: the brand title is `#app-title` (light DOM, plain selector).
  await driver.wait(until.elementLocated(By.id('app-title')), 90_000);
  const title = await driver.findElement(By.id('app-title')).getText();
  if (!/Chump/i.test(title)) {
    throw new Error(`Expected "Chump" in #app-title, got: ${JSON.stringify(title)}`);
  }

  // Wait for `<chump-chat>` to upgrade and attach its shadow root.
  await driver.wait(until.elementLocated(By.css('chump-chat')), 60_000);
  await driver.wait(async () => {
    const ready = await driver.executeScript(
      `return !!document.querySelector('chump-chat')?.shadowRoot?.getElementById('input');`,
    );
    return ready === true;
  }, 60_000, 'chump-chat shadow root never produced #input');

  // Type into the shadow-root textarea and click the shadow-root send button.
  // executeScript runs in page context where shadowRoot.getElementById works.
  const msg = `/task tauri-wd-${Date.now()}`;
  await driver.executeScript(
    `const sr = document.querySelector('chump-chat').shadowRoot;
     const t = sr.getElementById('input');
     t.value = arguments[0];
     t.dispatchEvent(new Event('input', { bubbles: true }));
     sr.getElementById('send-btn').click();`,
    msg,
  );

  // Wait for the assistant bubble inside the shadow root to receive the
  // expected text. Poll via executeScript since elementLocated can't pierce
  // shadow DOM either.
  await driver.wait(async () => {
    const text = await driver.executeScript(
      `const sr = document.querySelector('chump-chat').shadowRoot;
       const b = sr.querySelector('.message.assistant .bubble');
       return b ? (b.textContent || '') : null;`,
    );
    return typeof text === 'string' && text.includes('Created task');
  }, 90_000, 'assistant bubble never received "Created task"');
  console.log('tauri webdriver e2e: ok');
} finally {
  exiting = true;
  if (driver) {
    await driver.quit().catch(() => {});
  }
  if (tauriDriverProc && !tauriDriverProc.killed) {
    tauriDriverProc.kill('SIGTERM');
    await sleep(400);
    if (!tauriDriverProc.killed) tauriDriverProc.kill('SIGKILL');
  }
}
