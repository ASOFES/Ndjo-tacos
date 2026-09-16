import { createWriteStream, existsSync, mkdirSync, writeFileSync } from 'fs';
import { spawn, execSync } from 'child_process';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { PrismaClient } from '@prisma/client';

const here = dirname(fileURLToPath(import.meta.url));
const backend = join(here, '..');
const shots = join(here, 'offline-flutter-shots');
mkdirSync(shots, { recursive: true });

const APP = 'http://localhost:5192';
const API = 'http://localhost:3000';
const DEBUG = 9333;
const prisma = new PrismaClient();

function ok(name, pass, detail) {
  console.log(`${pass ? 'SUCCESS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
  if (!pass) process.exitCode = 1;
}

function pidOnPort(port) {
  const out = execSync('netstat -ano', { encoding: 'utf8' });
  const line = out
    .split(/\r?\n/)
    .find((row) => row.includes(`:${port}`) && row.includes('LISTENING'));
  if (!line) return null;
  return line.trim().split(/\s+/).pop();
}

function stopApi() {
  const pid = pidOnPort(3000);
  if (!pid || pid === '0') throw new Error('API 3000 introuvable');
  execSync(`taskkill /PID ${pid} /F`);
}

async function waitHealth(up, timeoutMs = 90000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const response = await fetch(`${API}/health`);
      if (up && response.ok) return;
    } catch {
      if (!up) return;
    }
    await new Promise((r) => setTimeout(r, 400));
  }
  if (up) throw new Error('API 3000 ne redémarre pas');
}

function startApi() {
  const child = spawn('npx', ['nest', 'start'], {
    cwd: backend,
    env: { ...process.env, NODE_OPTIONS: '--max-old-space-size=4096' },
    shell: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.pipe(createWriteStream(join(here, 'offline-nest-restart.log')));
  child.stderr.pipe(createWriteStream(join(here, 'offline-nest-restart.err.log')));
  return child;
}

function browserPath() {
  const candidates = [
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  ];
  return candidates.find((item) => existsSync(item));
}

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.pending = new Map();
    this.id = 0;
    ws.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id && this.pending.has(msg.id)) {
        const wait = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) wait.reject(new Error(msg.error.message));
        else wait.resolve(msg.result);
      }
    });
  }

  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP timeout ${method}`));
        }
      }, 30000);
    });
  }

  async eval(expression) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.text || 'eval error');
    }
    return result.result?.value;
  }
}

async function connectCdp() {
  const start = Date.now();
  while (Date.now() - start < 25000) {
    try {
      const list = await fetch(`http://127.0.0.1:${DEBUG}/json/list`).then((r) => r.json());
      const page =
        list.find((item) => item.type === 'page' && String(item.url || '').includes('5192')) ||
        list.find((item) => item.type === 'page' && item.webSocketDebuggerUrl);
      if (page?.webSocketDebuggerUrl) {
        const ws = new WebSocket(page.webSocketDebuggerUrl);
        await new Promise((resolve, reject) => {
          ws.addEventListener('open', resolve);
          ws.addEventListener('error', () => reject(new Error('ws')));
        });
        return new Cdp(ws);
      }
    } catch {
      /* retry */
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error('DevTools 9333 injoignable');
}

async function clickPoint(cdp, x, y) {
  const opts = { x: Math.round(x), y: Math.round(y), button: 'left', clickCount: 1 };
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...opts });
  await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...opts });
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...opts });
}

async function findHit(cdp, labels) {
  return cdp.eval(`(() => {
    const wanted = ${JSON.stringify(labels)};
    const hits = [];
    const walk = (root) => {
      if (!root?.querySelectorAll) return;
      for (const el of root.querySelectorAll('*')) {
        const id = el.getAttribute('flt-semantics-identifier') || '';
        const label = (el.getAttribute('aria-label') || el.innerText || el.textContent || '').trim();
        const r = el.getBoundingClientRect();
        if (wanted.some((item) => id === item || label === item || (item.length > 3 && label.includes(item)))) {
          hits.push({
            id,
            label: label.slice(0, 80),
            x: r.x + r.width / 2,
            y: r.y + r.height / 2,
            w: r.width,
            h: r.height,
          });
        }
        if (el.shadowRoot) walk(el.shadowRoot);
      }
    };
    walk(document);
    const host = document.querySelector('flt-semantics-host');
    if (host?.shadowRoot) walk(host.shadowRoot);
    return hits.find((item) => item.w >= 8 && item.h >= 8) || hits[0] || null;
  })()`);
}

async function click(cdp, labels, fallback) {
  const found = await findHit(cdp, labels);
  if (found && found.w >= 8) {
    await clickPoint(cdp, found.x, found.y);
    return found;
  }
  if (fallback) {
    await clickPoint(cdp, fallback.x, fallback.y);
    return fallback;
  }
  throw new Error(`introuvable: ${labels.join(', ')}`);
}

async function bodyText(cdp) {
  return (
    (await cdp.eval(`(() => {
      const parts = [document.body?.innerText || ''];
      document.querySelectorAll('flt-semantics, [aria-label]').forEach((el) => {
        parts.push(el.getAttribute('aria-label') || el.innerText || '');
      });
      const host = document.querySelector('flt-semantics-host');
      if (host?.shadowRoot) parts.push(host.shadowRoot.textContent || '');
      return parts.join('\\n');
    })()`)) || ''
  );
}

async function shot(cdp, name) {
  const result = await cdp.send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(join(shots, name), Buffer.from(result.data, 'base64'));
}

const edge = browserPath();
if (!edge) {
  ok('navigateur local', false, 'Edge/Chrome introuvable');
  await prisma.$disconnect();
  process.exit(1);
}

const existingDebug = pidOnPort(DEBUG);
if (existingDebug) execSync(`taskkill /PID ${existingDebug} /F`);

const profile = join(here, '.offline-edge-profile');
mkdirSync(profile, { recursive: true });
const browser = spawn(
  edge,
  [
    `--remote-debugging-port=${DEBUG}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1440,920',
    APP,
  ],
  { stdio: 'ignore' },
);

const before = await prisma.order.count();
console.log(`baseline PostgreSQL orders=${before}`);

let cdp;
let text = '';
try {
  cdp = await connectCdp();
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width: 1440,
    height: 920,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await cdp.send('Page.navigate', { url: APP });
  await cdp.eval(`new Promise((resolve) => {
    const started = Date.now();
    const timer = setInterval(() => {
      const ready = Boolean(document.querySelector('flutter-view, flt-glass-pane, canvas, flt-semantics-host'));
      if (ready || Date.now() - started > 25000) {
        clearInterval(timer);
        resolve({
          href: location.href,
          ready,
          title: document.title,
          html: document.documentElement.outerHTML.slice(0, 1500),
        });
      }
    }, 300);
  })`).then((info) => {
    writeFileSync(join(shots, 'dom.json'), JSON.stringify(info, null, 2));
    console.log(`page ${info?.href} ready=${info?.ready} title=${info?.title}`);
  });
  await new Promise((r) => setTimeout(r, 3000));
  await shot(cdp, '01-login.png');
  for (let i = 0; i < 15; i++) {
    text = await bodyText(cdp);
    if (text.includes('Se connecter')) break;
    await new Promise((r) => setTimeout(r, 500));
  }
  await click(cdp, ['login-submit', 'Se connecter'], { x: 720, y: 540 });
  for (let i = 0; i < 20; i++) {
    text = await bodyText(cdp);
    if (text.includes('Tableau de bord') || text.includes('Permissions')) break;
    await new Promise((r) => setTimeout(r, 500));
  }
  await shot(cdp, '02-after-login.png');
  ok('connexion 5192', text.includes('Tableau de bord') || text.includes('Permissions'), 'session admin ouverte');

  await click(cdp, ['nav-Caisse', 'Caisse'], { x: 110, y: 680 });
  await new Promise((r) => setTimeout(r, 4000));
  await shot(cdp, '03-caisse.png');
  text = await bodyText(cdp);
  ok('catalogue caisse visible', /Panier|Encaisser|Tacos|Fanta|Coca/.test(text), 'écran caisse');

  stopApi();
  await waitHealth(false, 15000);
  ok('API coupée', true, 'port 3000 arrêté');

  await click(cdp, ['pos-product-Fanta 330 ml', 'Fanta 330 ml', 'Sprite 330 ml', 'Tacos poulet'], { x: 330, y: 430 });
  await new Promise((r) => setTimeout(r, 800));
  await click(cdp, ['pos-checkout', 'Encaisser'], { x: 1280, y: 820 });
  await new Promise((r) => setTimeout(r, 800));
  await click(cdp, ['pay-confirm', 'Valider'], { x: 900, y: 620 });
  await new Promise((r) => setTimeout(r, 2500));
  await shot(cdp, '04-offline-sale.png');
  text = await bodyText(cdp);
  const localMatch = text.match(/LOCAL-[A-Z0-9]+/);
  ok('vente hors ligne LOCAL- + EN_ATTENTE_SYNC', Boolean(localMatch) && text.includes('EN_ATTENTE_SYNC'), localMatch?.[0]);
  const localNumber = localMatch?.[0] ?? '';

  await cdp.send('Page.reload', { ignoreCache: true });
  await new Promise((r) => setTimeout(r, 6000));
  try {
    await click(cdp, ['nav-Caisse', 'Caisse']);
  } catch {
    /* maybe already on POS for caissier */
  }
  await new Promise((r) => setTimeout(r, 2500));
  await shot(cdp, '05-reopen-offline.png');
  text = await bodyText(cdp);
  ok(
    'vente survit à fermeture/réouverture 5192',
    text.includes(localNumber) &&
      localNumber.startsWith('LOCAL-') &&
      (text.includes('EN_ATTENTE_SYNC') || text.includes('LOCAL-')),
    localNumber || 'LOCAL encore visible',
  );

  const nest = startApi();
  await waitHealth(true, 90000);
  ok('API rétablie', true, 'health 200');
  await new Promise((r) => setTimeout(r, 16000));
  try {
    await click(cdp, ['Sync']);
  } catch {
    /* auto flush */
  }
  await new Promise((r) => setTimeout(r, 3000));
  await shot(cdp, '06-after-sync.png');
  text = await bodyText(cdp);
  ok(
    'synchronisation automatique → numéro NDJ',
    text.includes('NDJ-2026-') && (!localNumber || !text.includes(localNumber)),
    (text.match(/NDJ-2026-\d+/) || [])[0] || 'numéro serveur',
  );

  const after = await prisma.order.count();
  ok('PostgreSQL : une seule vente créée par ce test', after - before === 1, `avant=${before} après=${after} delta=${after - before}`);
  nest.unref?.();
} catch (error) {
  if (cdp) await shot(cdp, '99-error.png').catch(() => {});
  ok('parcours Flutter 5192', false, error instanceof Error ? error.message : String(error));
} finally {
  try {
    browser.kill();
  } catch {
    /* ignore */
  }
  const edgePid = pidOnPort(DEBUG);
  if (edgePid) {
    try {
      execSync(`taskkill /PID ${edgePid} /F`);
    } catch {
      /* ignore */
    }
  }
  await prisma.$disconnect();
}
