import { randomBytes } from 'crypto';

export function createTrackingToken() {
  return randomBytes(18).toString('base64url');
}

export function isTrackingToken(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{12,48}$/.test(value.trim());
}
