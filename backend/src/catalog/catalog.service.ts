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
        ingredient: {
          id?: string;
          name: string;
          code?: string;
          kind?: string;
          priceBuy?: number;
          priceSell?: number;
        };
      }) => {
        const grams = item.unit === 'kg';
        const displayQty = grams
          ? `${Math.round(item.quantity * 1000)} g`
          : `${item.quantity} ${item.unit}`;
        const unitCost =
          item.ingredient.kind === 'VENTE'
            ? (item.ingredient.priceBuy ?? item.ingredient.priceSell ?? 0)
            : (item.ingredient.priceBuy ?? 0);
        const cost = Math.round(unitCost * item.quantity);
        return {
          ingredientId: item.ingredientId ?? item.ingredient.id,
          name: item.ingredient.name,
          code: item.ingredient.code,
          kind: item.ingredient.kind ?? 'INGREDIENT',
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
          status: { not: 'SUPPRIME' },
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
      await this.propagateFromProduct(product.id);
      return this.present(
        await this.prisma.product.findUniqueOrThrow({
          where: { id: product.id },
          include: includeSheet,
        }),
      );
    } catch (error) {
      if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
        throw new BadRequestException('Ce code produit existe déjà dans l’établissement');
      }
      throw error;
    }
  }

  async update(id: string, draft: ProductDraft, userId: string) {
    await this.assertCategory(draft.categoryId, draft.establishmentId);
    const before = await this.prisma.product.findUnique({ where: { id } });
    if (!before) throw new BadRequestException('Produit introuvable');
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
          details: `Fiche ${product.name} (${product.code}) · synchronisée sur tous les établissements`,
          newValue: JSON.stringify(data),
          establishmentId: product.establishmentId,
          userId,
        },
      });
      await this.propagateFromProduct(product.id, { matchCode: before.code });
      return this.present(
        await this.prisma.product.findUniqueOrThrow({
          where: { id: product.id },
          include: includeSheet,
        }),
      );
    } catch (error) {
      if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
        throw new BadRequestException('Ce code produit existe déjà dans l’établissement');
      }
      throw error;
    }
  }

  async remove(id: string, userId: string) {
    const product = mustExistProduct(
      await this.prisma.product.findUnique({
        where: { id },
        include: {
          lots: { select: { qtyCurrent: true } },
          establishment: { select: { name: true } },
        },
      }),
    );
    if (product.status === 'SUPPRIME') {
      return this.present(
        await this.prisma.product.findUniqueOrThrow({ where: { id }, include: includeSheet }),
      );
    }

    const siblings = await this.prisma.product.findMany({
      where: { code: product.code, status: { not: 'SUPPRIME' } },
      include: {
        lots: { select: { qtyCurrent: true } },
        establishment: { select: { name: true, code: true } },
      },
    });

    const withStock = siblings.filter(
      (row) => row.lots.reduce((sum, lot) => sum + Number(lot.qtyCurrent), 0) > 0.0001,
    );
    if (withStock.length) {
      const sites = withStock.map((row) => row.establishment.name).join(', ');
      throw new BadRequestException(
        `Impossible de supprimer : stock encore présent (${sites}). Sortez, transférez ou inventoriez d’abord.`,
      );
    }

    for (const row of siblings) {
      const usedInRecipes = await this.prisma.recipeItem.count({
        where: { ingredientId: row.id },
      });
      if (usedInRecipes > 0) {
        throw new BadRequestException(
          `Impossible de supprimer : ${row.name} est utilisé dans ${usedInRecipes} recette(s) (${row.establishment.name}). Retirez-le des compositions d’abord.`,
        );
      }
    }

    for (const row of siblings) {
      await this.prisma.product.update({
        where: { id: row.id },
        data: { status: 'SUPPRIME' },
      });
      await this.prisma.auditLog.create({
        data: {
          action: 'SUPPRIMER',
          entity: 'PRODUIT',
          entityId: row.id,
          details: `Fiche ${row.name} (${row.code}) supprimée · sync multi-sites`,
          oldValue: JSON.stringify({ status: row.status }),
          newValue: JSON.stringify({ status: 'SUPPRIME' }),
          establishmentId: row.establishmentId,
          userId,
        },
      });
    }

    return this.present(
      await this.prisma.product.findUniqueOrThrow({ where: { id }, include: includeSheet }),
    );
  }

  /** Propagate fiche (hors lots/stock) vers tous les autres établissements, clé = code produit. */
  async propagateFromProduct(sourceId: string, opts?: { matchCode?: string }) {
    const source = await this.prisma.product.findUnique({
      where: { id: sourceId },
      include: {
        category: true,
        recipe: { include: { items: { include: { ingredient: true } } } },
      },
    });
    if (!source || source.status === 'SUPPRIME') return;

    const others = await this.prisma.establishment.findMany({
      where: { id: { not: source.establishmentId } },
      select: { id: true },
    });
    const matchCode = opts?.matchCode ?? source.code;
    for (const est of others) {
      await this.mirrorProductToSite(source, est.id, matchCode);
    }
  }

  /** Propagate recette d’un produit vers les autres sites (après POST /recipes). */
  async propagateRecipe(productId: string) {
    await this.propagateFromProduct(productId);
  }

  private async ensureCategoryId(name: string, establishmentId: string) {
    const trimmed = name.trim() || 'Divers';
    const existing = await this.prisma.category.findFirst({
      where: { establishmentId, name: trimmed },
    });
    if (existing) return existing.id;
    const created = await this.prisma.category.create({
      data: { name: trimmed, establishmentId },
    });
    return created.id;
  }

  private sheetData(source: {
    code: string;
    name: string;
    description: string | null;
    unit: string;
    priceBuy: number;
    priceSell: number;
    stockAlert: number;
    photoUrl: string | null;
    subcategory: string | null;
    volume: string | null;
    format: string | null;
    supplier: string | null;
    kind: string;
    status: string;
  }) {
    return {
      code: source.code,
      name: source.name,
      description: source.description,
      unit: source.unit,
      priceBuy: source.priceBuy,
      priceSell: source.priceSell,
      stockAlert: source.stockAlert,
      photoUrl: source.photoUrl,
      subcategory: source.subcategory,
      volume: source.volume,
      format: source.format,
      supplier: source.supplier,
      kind: source.kind,
      status: source.status,
    };
  }

  private async mirrorProductToSite(
    source: {
      id: string;
      code: string;
      name: string;
      description: string | null;
      unit: string;
      priceBuy: number;
      priceSell: number;
      stockAlert: number;
      photoUrl: string | null;
      subcategory: string | null;
      volume: string | null;
      format: string | null;
      supplier: string | null;
      kind: string;
      status: string;
      category: { name: string };
      recipe: {
        items: {
          quantity: number;
          unit: string;
          ingredient: {
            id: string;
            code: string;
            name: string;
            description: string | null;
            unit: string;
            priceBuy: number;
            priceSell: number;
            stockAlert: number;
            photoUrl: string | null;
            subcategory: string | null;
            volume: string | null;
            format: string | null;
            supplier: string | null;
            kind: string;
            status: string;
            categoryId: string;
          };
        }[];
      } | null;
    },
    destEstId: string,
    matchCode: string,
  ) {
    const categoryId = await this.ensureCategoryId(source.category.name, destEstId);
    const existing =
      (await this.prisma.product.findFirst({
        where: { establishmentId: destEstId, code: matchCode },
      })) ??
      (matchCode !== source.code
        ? await this.prisma.product.findFirst({
            where: { establishmentId: destEstId, code: source.code },
          })
        : null);

    const data = { ...this.sheetData(source), categoryId };
    const destProduct = existing
      ? await this.prisma.product.update({ where: { id: existing.id }, data })
      : await this.prisma.product.create({
          data: { ...data, establishmentId: destEstId },
        });

    await this.mirrorRecipe(source, destProduct.id, destEstId);
  }

  private async mirrorRecipe(
    source: {
      recipe: {
        items: {
          quantity: number;
          unit: string;
          ingredient: {
            code: string;
            name: string;
            description: string | null;
            unit: string;
            priceBuy: number;
            priceSell: number;
            stockAlert: number;
            photoUrl: string | null;
            subcategory: string | null;
            volume: string | null;
            format: string | null;
            supplier: string | null;
            kind: string;
            status: string;
            category?: { name: string } | null;
          } & { categoryId?: string };
        }[];
      } | null;
    },
    destProductId: string,
    destEstId: string,
  ) {
    if (!source.recipe) {
      await this.prisma.recipe.deleteMany({ where: { productId: destProductId } });
      return;
    }

    const items: { ingredientId: string; quantity: number; unit: string }[] = [];
    for (const item of source.recipe.items) {
      const ingredientId = await this.ensureIngredientOnSite(item.ingredient, destEstId);
      items.push({
        ingredientId,
        quantity: item.quantity,
        unit: item.unit,
      });
    }

    await this.prisma.recipe.upsert({
      where: { productId: destProductId },
      update: {
        items: {
          deleteMany: {},
          create: items,
        },
      },
      create: {
        productId: destProductId,
        establishmentId: destEstId,
        items: { create: items },
      },
    });
  }

  private async ensureIngredientOnSite(
    ingredient: {
      code: string;
      name: string;
      description: string | null;
      unit: string;
      priceBuy: number;
      priceSell: number;
      stockAlert: number;
      photoUrl: string | null;
      subcategory: string | null;
      volume: string | null;
      format: string | null;
      supplier: string | null;
      kind: string;
      status: string;
    },
    destEstId: string,
  ) {
    const existing = await this.prisma.product.findFirst({
      where: { establishmentId: destEstId, code: ingredient.code },
    });
    if (existing) {
      if (existing.status === 'SUPPRIME' || existing.name !== ingredient.name) {
        await this.prisma.product.update({
          where: { id: existing.id },
          data: {
            ...this.sheetData(ingredient),
            status: ingredient.status === 'SUPPRIME' ? 'ACTIF' : ingredient.status,
          },
        });
      }
      return existing.id;
    }

    const sourceFull = await this.prisma.product.findFirst({
      where: { code: ingredient.code, status: { not: 'SUPPRIME' } },
      include: { category: true },
      orderBy: { updatedAt: 'desc' },
    });
    const categoryName = sourceFull?.category?.name ?? 'Ingrédients';
    const categoryId = await this.ensureCategoryId(categoryName, destEstId);
    const created = await this.prisma.product.create({
      data: {
        ...this.sheetData(ingredient),
        status: ingredient.status === 'SUPPRIME' ? 'ACTIF' : ingredient.status,
        establishmentId: destEstId,
        categoryId,
      },
    });
    return created.id;
  }
}

function mustExistProduct<T>(value: T | null): T {
  if (value == null) {
    throw new BadRequestException('Produit introuvable');
  }
  return value;
}
