import { networkInterfaces } from 'os';

export function lanIpv4(): string[] {
  const found: string[] = [];
  for (const list of Object.values(networkInterfaces())) {
    for (const net of list ?? []) {
      const family = net.family === 'IPv4' || (net.family as unknown) === 4;
      if (!family || net.internal) continue;
      found.push(net.address);
    }
  }
  return [...new Set(found)];
}

export function lanUrls(port: number): string[] {
  return lanIpv4().map((ip) => `http://${ip}:${port}`);
}

export function isPrivateHttpOrigin(origin: string): boolean {
  try {
    const url = new URL(origin);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
    const host = url.hostname.toLowerCase();
    if (host === 'localhost' || host === '127.0.0.1') return true;
    const parts = host.split('.');
    if (parts.length !== 4) return false;
    const [a, b, c, d] = parts.map(Number);
    if ([a, b, c, d].some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
      return false;
    }
    if (a === 10) return true;
    if (a === 192 && b === 168) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    return false;
  } catch {
    return false;
  }
}

export function lanInfo(apiPort: number, appPort = 5192) {
  const ips = lanIpv4();
  return {
    ok: true,
    internetRequired: false,
    apiPort,
    appPort,
    ips,
    apiUrls: ips.map((ip) => `http://${ip}:${apiPort}`),
    appUrls: ips.map((ip) => `http://${ip}:${appPort}`),
  };
}
