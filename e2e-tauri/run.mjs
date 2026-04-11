/**
 * Drives the real Chump (Cowork) Tauri shell via tauri-driver + WebKitWebDriver (Linux).
 * Prereqs: Linux, WebKitWebDriver on PATH, `cargo install tauri-driver --locked`,
 * `target/debug/chump-desktop` + `target/debug/chump`, chump --web already listening
 * (see scripts/run-tauri-e2e.sh).
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

  await driver.wait(until.elementLocated(By.css('header h1')), 90_000);
  const h1 = await driver.findElement(By.css('header h1'));
  const title = await h1.getText();
  if (!/Chump/i.test(title)) {
    throw new Error(`Expected "Chump" in header h1, got: ${JSON.stringify(title)}`);
  }

  await driver.wait(until.elementLocated(By.id('msg-input')), 60_000);
  const msg = `/task tauri-wd-${Date.now()}`;
  const input = await driver.findElement(By.id('msg-input'));
  await input.clear();
  await input.sendKeys(msg);
  await driver.findElement(By.id('send-btn')).click();

  await driver.wait(until.elementLocated(By.css('.message.assistant .bubble')), 90_000);
  const bubble = await driver.findElement(By.css('.message.assistant .bubble'));
  const reply = await bubble.getText();
  if (!reply.includes('Created task')) {
    throw new Error(`Expected Created task in assistant bubble, got: ${JSON.stringify(reply.slice(0, 400))}`);
  }
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
