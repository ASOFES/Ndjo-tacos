import { BadRequestException, Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma.service';

export type ProductDraft = {
  code: string;
  name: string;
  description?: string | null;
  unit: string;
  priceBuy: number;
  priceSell: number;
  stockAlert: number;
  photoUrl?: string | null;
  subcategory?: string | null;
  volume?: string | null;
  format?: string | null;
  supplier?: string | null;
  kind: string;
  status: string;
  categoryId: string;
  establishmentId: string;
};

function emptyToNull(value: unknown) {
  if (value == null) return null;
  const text = String(value).trim();
  return text.length ? text : null;
}

export function toProductDraft(
  body: Record<string, unknown>,
  establishmentId: string,
): ProductDraft {
  const code = String(body.code ?? '').trim();
  const name = String(body.name ?? '').trim();
  const categoryId = String(body.categoryId ?? '').trim();
  if (!code || !name || !categoryId) {
    throw new BadRequestException('Code, nom et catégorie sont obligatoires');
  }
  return {
    code,
    name,
    description: emptyToNull(body.description),
    unit: String(body.unit ?? 'pièce').trim() || 'pièce',
    priceBuy: Number(body.priceBuy ?? 0),
    priceSell: Number(body.priceSell ?? 0),
    stockAlert: Number(body.stockAlert ?? 5),
    photoUrl: emptyToNull(body.photoUrl),
    subcategory: emptyToNull(body.subcategory),
    volume: emptyToNull(body.volume),
    format: emptyToNull(body.format) ?? 'Unitaire',
    supplier: emptyToNull(body.supplier),
    kind: String(body.kind ?? 'VENTE'),
    status: String(body.status ?? 'ACTIF'),
    categoryId,
    establishmentId,
  };
}

const includeSheet = {
  category: true,
  lots: { orderBy: [{ expiryDate: 'asc' as const }, { createdAt: 'asc' as const }] },
  recipe: { include: { items: { include: { ingredient: true } } } },
};

@Injectable()
export class CatalogService {
  constructor(private readonly prisma: PrismaService) {}

  async assertCategory(categoryId: string, establishmentId: string) {
    const category = await this.prisma.category.findUnique({
      where: { id: categoryId },
    });
    if (!category || category.establishmentId !== establishmentId) {
      throw new BadRequestException('Catégorie hors établissement');
    }
    return category;
  }

  present(product: any) {
    const composition = (product.recipe?.items ?? []).map(
      (item: {
        quantity: number;
        unit: string;
        ingredientId?: string;
        ingredient: { id?: string; name: string; code?: string; priceBuy?: number };
      }) => {
        const grams = item.unit === 'kg';
        const displayQty = grams
          ? `${Math.round(item.quantity * 1000)} g`
          : `${item.quantity} ${item.unit}`;
        const cost = Math.round((item.ingredient.priceBuy ?? 0) * item.quantity);
        return {
          ingredientId: item.ingredientId ?? item.ingredient.id,
          name: item.ingredient.name,
          code: item.ingredient.code,
          quantity: item.quantity,
          qtyShown: grams ? Math.round(item.quantity * 1000) : item.quantity,
          unit: item.unit,
          unitShown: grams ? 'g' : item.unit,
          displayQty,
          cost,
          line: `${displayQty} ${item.ingredient.name.toLowerCase()}`,
        };
      },
    );
    const recipeCost = composition.reduce((sum: number, row: { cost: number }) => sum + row.cost, 0);
    const priceSell = Number(product.priceSell ?? 0);
    return {
      ...product,
      stockQty: (product.lots ?? []).reduce(
        (sum: number, lot: { qtyCurrent: number }) => sum + lot.qtyCurrent,
        0,
      ),
      composition,
      recipeText: composition.map((row: { line: string }) => row.line).join(' · '),
      recipeCost,
      recipeMargin: priceSell - recipeCost,
    };
  }

  list(establishmentId: string, kind?: string) {
    return this.prisma.product
      .findMany({
        where: {
          establishmentId,
          ...(kind && kind !== 'TOUS' ? { kind } : {}),
        },
        include: includeSheet,
        orderBy: [{ kind: 'asc' }, { name: 'asc' }],
      })
      .then((rows) => rows.map((row) => this.present(row)));
  }

  async create(draft: ProductDraft, userId: string) {
    await this.assertCategory(draft.categoryId, draft.establishmentId);
    try {
      const product = await this.prisma.product.create({
        data: draft,
        include: includeSheet,
      });
      await this.prisma.auditLog.create({
        data: {
          action: 'CREER',
          entity: 'PRODUIT',
          entityId: product.id,
          details: `Fiche produit ${product.name} (${product.code})`,
          newValue: JSON.stringify(draft),
          establishmentId: draft.establishmentId,
          userId,
        },
      });
      return this.present(product);
    } catch (error) {
      if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
        throw new BadRequestException('Ce code produit existe déjà dans l’établissement');
      }
      throw error;
    }
  }

  async update(id: string, draft: ProductDraft, userId: string) {
    await this.assertCategory(draft.categoryId, draft.establishmentId);
    const { establishmentId: _ignored, ...data } = draft;
    try {
      const product = await this.prisma.product.update({
        where: { id },
        data,
        include: includeSheet,
      });
      await this.prisma.auditLog.create({
        data: {
          action: 'MODIFIER',
          entity: 'PRODUIT',
          entityId: product.id,
          details: `Fiche ${product.name} (${product.code})`,
          newValue: JSON.stringify(data),
          establishmentId: product.establishmentId,
          userId,
        },
      });
      return this.present(product);
    } catch (error) {
      if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
        throw new BadRequestException('Ce code produit existe déjà dans l’établissement');
      }
      throw error;
    }
  }
}
