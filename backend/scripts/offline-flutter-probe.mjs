import { existsSync, mkdirSync, writeFileSync } from 'fs';
import { spawn, execSync } from 'child_process';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const shots = join(here, 'offline-flutter-shots');
mkdirSync(shots, { recursive: true });
const APP = 'http://localhost:5192';
const DEBUG = 9333;

function pidOnPort(port) {
  const out = execSync('netstat -ano', { encoding: 'utf8' });
  const line = out.split(/\r?\n/).find((row) => row.includes(`:${port}`) && row.includes('LISTENING'));
  return line ? line.trim().split(/\s+/).pop() : null;
}

function browserPath() {
  return [
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  ].find((item) => existsSync(item));
}

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.pending = new Map();
    this.id = 0;
    this.events = [];
    ws.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data);
      if (msg.method) this.events.push(msg);
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
      }, 20000);
    });
  }
  async eval(expression) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      throw new Error(
        result.exceptionDetails.exception?.description ||
          result.exceptionDetails.text ||
          'eval',
      );
    }
    return result.result?.value;
  }
}

const existing = pidOnPort(DEBUG);
if (existing) execSync(`taskkill /PID ${existing} /F`);

const profile = join(here, '.offline-edge-profile');
mkdirSync(profile, { recursive: true });
const edge = browserPath();
const browser = spawn(edge, [
  `--remote-debugging-port=${DEBUG}`,
  `--user-data-dir=${profile}`,
  '--no-first-run',
  '--window-size=1440,920',
  APP,
], { stdio: 'ignore' });

await new Promise((r) => setTimeout(r, 2500));
let page;
for (let i = 0; i < 40; i++) {
  try {
    const list = await fetch(`http://127.0.0.1:${DEBUG}/json/list`).then((r) => r.json());
    page = list.find((item) => String(item.url || '').includes('5192')) || list.find((item) => item.type === 'page');
    if (page?.webSocketDebuggerUrl) break;
  } catch {}
  await new Promise((r) => setTimeout(r, 250));
}
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.addEventListener('open', resolve);
  ws.addEventListener('error', () => reject(new Error('ws')));
});
const cdp = new Cdp(ws);
await cdp.send('Page.enable');
await cdp.send('Runtime.enable');
await cdp.send('Log.enable');
await cdp.send('Network.enable');
await cdp.send('Page.navigate', { url: APP });
await new Promise((r) => setTimeout(r, 3000));
const start = Date.now();
let info = { href: '', canvases: 0, flutterView: false, text: '', dpr: 1, size: { w: 0, h: 0 } };
while (Date.now() - start < 45000) {
  try {
    info = await cdp.eval(`({
      href: location.href,
      canvases: document.querySelectorAll('canvas').length,
      flutterView: Boolean(document.querySelector('flutter-view, flt-glass-pane, flt-semantics-host')),
      text: document.body ? String(document.body.innerText || '').slice(0, 500) : '',
      dpr: devicePixelRatio,
      size: { w: innerWidth, h: innerHeight },
    })`);
    if (info.canvases > 0 || info.flutterView || (info.text && info.text.includes('NDJO'))) break;
  } catch (error) {
    info.text = String(error.message || error);
  }
  await new Promise((r) => setTimeout(r, 1000));
}
console.log('waited_ms', Date.now() - start);
writeFileSync(join(shots, 'probe.json'), JSON.stringify(info, null, 2));

const ax = await cdp.send('Accessibility.getFullAXTree');
const names = (ax.nodes || [])
  .map((node) => ({
    role: node.role?.value,
    name: node.name?.value,
    ignored: node.ignored,
  }))
  .filter((node) => node.name && !node.ignored)
  .slice(0, 80);
writeFileSync(join(shots, 'ax.json'), JSON.stringify(names, null, 2));

const shot = await cdp.send('Page.captureScreenshot', { format: 'png', fromSurface: true });
writeFileSync(join(shots, 'probe.png'), Buffer.from(shot.data, 'base64'));
const consoles = cdp.events
  .filter((item) => item.method === 'Runtime.consoleAPICalled' || item.method === 'Log.entryAdded' || item.method === 'Runtime.exceptionThrown')
  .slice(-20);
writeFileSync(join(shots, 'console.json'), JSON.stringify(consoles, null, 2));
console.log(JSON.stringify({ info, axCount: names.length, first: names.slice(0, 15), consoles: consoles.length }, null, 2));

browser.kill();
const leftover = pidOnPort(DEBUG);
if (leftover) {
  try { execSync(`taskkill /PID ${leftover} /F`); } catch {}
}
