import { existsSync, mkdirSync, writeFileSync } from 'fs';
import { spawn, execSync } from 'child_process';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const shots = join(here, 'menu-offline-shots');
mkdirSync(shots, { recursive: true });

const APP = 'http://localhost:5192';
const API = 'http://localhost:3000';
const DEBUG = 9344;

const MENUS = [
  'Tableau de bord',
  'Rapports',
  'Organisation',
  'Utilisateurs',
  'Permissions',
  'Catalogue',
  'Clients',
  'Recettes',
  'Stock',
  'Inventaire',
  'Pertes',
  'Achats',
  'Caisse',
  'Commandes',
  'Cuisine',
  'Livraisons',
  'Factures',
  'Mises à jour',
  'Paramètres',
  'Synchronisation',
  'Système',
];

const FAIL_RX = /indisponible hors ligne|Exception:|ClientException|SocketException|TimeoutException|type 'Null' is not a subtype|RenderFlex overflowed/i;

function log(name, pass, detail) {
  console.log(`${pass ? 'OK' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
}

function pidOnPort(port) {
  const out = execSync('netstat -ano', { encoding: 'utf8' });
  const line = out
    .split(/\r?\n/)
    .find((row) => row.includes(`:${port}`) && row.includes('LISTENING'));
  if (!line) return null;
  return line.trim().split(/\s+/).pop();
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
  throw new Error('DevTools injoignable');
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
          hits.push({ id, label: label.slice(0, 80), x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height });
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

async function typeInto(cdp, text) {
  for (const ch of text) {
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', text: ch, unmodifiedText: ch });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', text: ch, unmodifiedText: ch });
  }
}

async function selectAll(cdp) {
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Control', windowsVirtualKeyCode: 17, modifiers: 2 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'a', windowsVirtualKeyCode: 65, modifiers: 2 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', windowsVirtualKeyCode: 65, modifiers: 2 });
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Control', windowsVirtualKeyCode: 17 });
}

async function login(cdp) {
  let text = '';
  for (let i = 0; i < 30; i++) {
    text = await bodyText(cdp);
    if (text.includes('Tableau de bord') || text.includes('Permissions') || text.includes('Synchronisation')) return true;
    if (text.includes('Se connecter') || text.includes('Nom utilisateur')) break;
    await new Promise((r) => setTimeout(r, 400));
  }
  await shot(cdp, '00-login.png');
  await clickPoint(cdp, 720, 395);
  await new Promise((r) => setTimeout(r, 200));
  await selectAll(cdp);
  await typeInto(cdp, 'admin');
  await clickPoint(cdp, 720, 460);
  await new Promise((r) => setTimeout(r, 200));
  await selectAll(cdp);
  await typeInto(cdp, 'admin123');
  await shot(cdp, '00-login-filled.png');
  await click(cdp, ['login-submit', 'Se connecter'], { x: 720, y: 545 });
  for (let i = 0; i < 40; i++) {
    text = await bodyText(cdp);
    if (text.includes('Tableau de bord') || text.includes('Permissions') || text.includes('Synchronisation') || text.includes('Caisse')) {
      await shot(cdp, '00-after-login.png');
      return true;
    }
    await new Promise((r) => setTimeout(r, 400));
  }
  await shot(cdp, '00-login-failed.png');
  writeFileSync(join(shots, 'login-text.txt'), text);
  return false;
}

async function visitMenus(cdp, tag) {
  const results = [];
  for (let i = 0; i < MENUS.length; i++) {
    const name = MENUS[i];
    try {
      await click(cdp, [`nav-${name}`, name], { x: 110, y: 88 + i * 36 });
    } catch {
      await clickPoint(cdp, 110, 88 + i * 36);
    }
    await new Promise((r) => setTimeout(r, 2200));
    const text = await bodyText(cdp);
    await shot(cdp, `${tag}-${String(i).padStart(2, '0')}-${name.replace(/[^\w]+/g, '_')}.png`);
    const blocked = FAIL_RX.test(text);
    const visible = text.includes(name) || text.length > 40;
    const pass = !blocked && visible;
    results.push({ name, pass, blocked, sample: text.replace(/\s+/g, ' ').slice(0, 160) });
    log(`${tag} ${name}`, pass, blocked ? 'écran bloqué' : visible ? 'page ouverte' : 'contenu vide');
  }
  return results;
}

const edge = browserPath();
if (!edge) {
  console.log('FAIL  navigateur introuvable');
  process.exit(1);
}

let apiWasUp = false;
try {
  const health = await fetch(`${API}/health`);
  apiWasUp = health.ok;
} catch {
  apiWasUp = false;
}

const existingDebug = pidOnPort(DEBUG);
if (existingDebug) execSync(`taskkill /PID ${existingDebug} /F`);

const profile = join(here, '.menu-offline-edge-profile-2');
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

let cdp;
const report = { online: [], offline: [] };
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
  await new Promise((r) => setTimeout(r, 7000));
  const logged = await login(cdp);
  log('login', logged);
  if (!logged) throw new Error('login échoué');

  if (apiWasUp) {
    report.online = await visitMenus(cdp, 'online');
    const pid = pidOnPort(3000);
    if (pid) execSync(`taskkill /PID ${pid} /F`);
    await new Promise((r) => setTimeout(r, 800));
    log('API coupée', true);
  }

  await cdp.send('Page.reload', { ignoreCache: true });
  await new Promise((r) => setTimeout(r, 5000));
  await login(cdp);
  report.offline = await visitMenus(cdp, 'offline');
} catch (error) {
  if (cdp) await shot(cdp, '99-error.png').catch(() => {});
  log('parcours', false, error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
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
}

const offlineFail = report.offline.filter((item) => !item.pass);
writeFileSync(join(shots, 'report.json'), JSON.stringify({ apiWasUp, offlineFail, ...report }, null, 2));
console.log(`OFFLINE_PASS=${report.offline.filter((item) => item.pass).length}/${report.offline.length}`);
console.log(`OFFLINE_FAIL=${offlineFail.map((item) => item.name).join(', ') || 'aucun'}`);
if (offlineFail.length) process.exitCode = 1;
