/** JWT / refresh TTL from env (`12h`, `30d`, `90d`). */

export function jwtAccessTtl(): string {
  return process.env.JWT_ACCESS_TTL?.trim() || '30d';
}

export function jwtRefreshTtlMs(): number {
  const raw = process.env.JWT_REFRESH_TTL?.trim() || '90d';
  const match = raw.match(/^(\d+)\s*(ms|s|m|h|d)$/i);
  if (!match) return 90 * 86_400_000;
  const amount = Number(match[1]);
  const unit = match[2].toLowerCase();
  if (unit === 'ms') return amount;
  if (unit === 's') return amount * 1000;
  if (unit === 'm') return amount * 60_000;
  if (unit === 'h') return amount * 3_600_000;
  return amount * 86_400_000;
}
