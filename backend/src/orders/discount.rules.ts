/** Règles de remise par catégorie client (caisse). */
export const CUSTOMER_CATEGORIES = ['STANDARD', 'REUNION', 'PROMOTION'] as const;
export type CustomerCategory = (typeof CUSTOMER_CATEGORIES)[number];

export type DiscountRule = {
  label: string;
  /** Plafond absolu (%). */
  maxPercent: number;
  /** Au-delà : validation GESTIONNAIRE / ADMIN requise. */
  autoPercent: number;
};

export const DISCOUNT_RULES: Record<CustomerCategory, DiscountRule> = {
  STANDARD: { label: 'Standard', maxPercent: 0, autoPercent: 0 },
  REUNION: { label: 'Réunion / entreprise', maxPercent: 15, autoPercent: 10 },
  PROMOTION: { label: 'Promotion', maxPercent: 25, autoPercent: 10 },
};

export function normalizeCustomerCategory(raw?: string | null): CustomerCategory {
  const value = String(raw ?? 'STANDARD').toUpperCase();
  if (value === 'REUNION' || value === 'PROMOTION') return value;
  return 'STANDARD';
}

export function resolveDiscount(params: {
  category?: string | null;
  percent: number;
  subtotal: number;
}) {
  const category = normalizeCustomerCategory(params.category);
  const rule = DISCOUNT_RULES[category];
  const percent = Math.max(0, Math.min(100, Math.round(Number(params.percent) || 0)));
  if (percent <= 0 || rule.maxPercent <= 0) {
    return {
      category,
      rule,
      percent: 0,
      amount: 0,
      needsApproval: false,
    };
  }
  if (percent > rule.maxPercent) {
    throw new Error(
      `Remise max ${rule.maxPercent}% pour la catégorie ${rule.label} (demandé ${percent}%)`,
    );
  }
  const amount = Math.round((params.subtotal * percent) / 100);
  return {
    category,
    rule,
    percent,
    amount,
    needsApproval: percent > rule.autoPercent,
  };
}
