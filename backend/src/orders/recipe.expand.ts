import { BadRequestException } from '@nestjs/common';
import { Prisma, PrismaClient } from '@prisma/client';

type Tx = Prisma.TransactionClient | PrismaClient;

export type RecipeLeafNeed = {
  productId: string;
  name: string;
  quantity: number;
};

/** Aplatit une recette (menus = produits vente + ingrédients) jusqu’aux feuilles stockables. */
export async function expandRecipeLeaves(
  tx: Tx,
  productId: string,
  quantity: number,
  opts?: { maxDepth?: number },
): Promise<RecipeLeafNeed[]> {
  const maxDepth = opts?.maxDepth ?? 8;
  const merged = new Map<string, RecipeLeafNeed>();

  const walk = async (id: string, qty: number, depth: number, stack: Set<string>) => {
    if (qty <= 0.0000001) return;
    if (depth > maxDepth) {
      throw new BadRequestException('Recette trop imbriquée (menu dans menu…)');
    }
    if (stack.has(id)) {
      throw new BadRequestException('Boucle de recette détectée (un produit se contient lui-même)');
    }
    const product = await tx.product.findUnique({
      where: { id },
      include: {
        recipe: { include: { items: { include: { ingredient: { select: { id: true, name: true } } } } } },
      },
    });
    if (!product) return;

    const items = product.recipe?.items ?? [];
    if (!items.length) {
      const row = merged.get(id) ?? { productId: id, name: product.name, quantity: 0 };
      row.quantity += qty;
      merged.set(id, row);
      return;
    }

    const nextStack = new Set(stack);
    nextStack.add(id);
    for (const item of items) {
      await walk(item.ingredientId, item.quantity * qty, depth + 1, nextStack);
    }
  };

  await walk(productId, quantity, 0, new Set());
  return [...merged.values()].map((row) => ({
    ...row,
    quantity: Math.round(row.quantity * 1000) / 1000,
  }));
}

export async function assertRecipeItemsValid(
  tx: Tx,
  params: {
    establishmentId: string;
    productId: string;
    items: { ingredientId: string; quantity: number; unit: string }[];
  },
) {
  if (!params.items.length) return;
  const ids = [...new Set(params.items.map((item) => item.ingredientId))];
  if (ids.includes(params.productId)) {
    throw new BadRequestException('Un produit ne peut pas se contenir dans sa propre recette');
  }
  const products = await tx.product.findMany({
    where: { id: { in: ids } },
    select: { id: true, name: true, status: true, establishmentId: true },
  });
  if (products.length !== ids.length) {
    throw new BadRequestException('Composant de recette introuvable');
  }
  for (const product of products) {
    if (product.establishmentId !== params.establishmentId) {
      throw new BadRequestException(`Composant hors établissement : ${product.name}`);
    }
    if (product.status === 'SUPPRIME') {
      throw new BadRequestException(`Composant supprimé : ${product.name}`);
    }
  }
  await assertNoCycleThrough(tx, params.productId, ids);
}

async function assertNoCycleThrough(tx: Tx, rootId: string, directChildIds: string[]) {
  const visit = async (id: string, stack: Set<string>) => {
    if (id === rootId || stack.has(id)) {
      throw new BadRequestException('Boucle de recette détectée (association circulaire de produits)');
    }
    const product = await tx.product.findUnique({
      where: { id },
      include: { recipe: { include: { items: true } } },
    });
    const items = product?.recipe?.items ?? [];
    if (!items.length) return;
    const next = new Set(stack);
    next.add(id);
    for (const item of items) {
      await visit(item.ingredientId, next);
    }
  };
  for (const childId of directChildIds) {
    await visit(childId, new Set());
  }
}
