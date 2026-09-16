export function normalizePhone(raw?: string | null) {
  if (!raw) return null;
  let digits = raw.replace(/[^\d+]/g, '');
  if (digits.startsWith('+')) digits = digits.slice(1);
  if (digits.startsWith('00')) digits = digits.slice(2);
  if (digits.startsWith('0') && digits.length === 10) digits = `243${digits.slice(1)}`;
  if (digits.length === 9 && /^[89]/.test(digits)) digits = `243${digits}`;
  if (!digits.startsWith('243') && digits.length === 12 && digits.startsWith('243')) {
    return digits;
  }
  return digits || null;
}

export function whatsappTo(raw?: string | null) {
  return normalizePhone(raw);
}
