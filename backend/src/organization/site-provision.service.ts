import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma.service';

@Injectable()
export class SiteProvisionService {
  constructor(private readonly prisma: PrismaService) {}

  async ensureReady(establishmentId: string | undefined | null) {
    const destId = String(establishmentId ?? '').trim();
    if (!destId) return;
    const existing = await this.prisma.product.count({ where: { establishmentId: destId } });
    if (existing > 0) return;
    const sourceId = await this.pickSource(destId);
    if (!sourceId) return;
    await this.cloneFrom(sourceId, destId);
  }

  private async pickSource(destId: string) {
    const rows = await this.prisma.product.groupBy({
      by: ['establishmentId'],
      _count: { id: true },
      orderBy: { _count: { id: 'desc' } },
    });
    return rows.find((row) => row.establishmentId !== destId && row._count.id > 0)?.establishmentId ?? null;
  }

  private async cloneFrom(sourceId: string, destId: string) {
    await this.prisma.$transaction(async (tx) => {
      const already = await tx.product.count({ where: { establishmentId: destId } });
      if (already > 0) return;

      const departments = await tx.department.findMany({ where: { establishmentId: sourceId } });
      for (const department of departments) {
        await tx.department.upsert({
          where: {
            establishmentId_name: { establishmentId: destId, name: department.name },
          },
          update: {},
          create: {
            name: department.name,
            status: department.status,
            establishmentId: destId,
          },
        });
      }

      const categories = await tx.category.findMany({ where: { establishmentId: sourceId } });
      const categoryIds = new Map<string, string>();
      for (const category of categories) {
        const created = await tx.category.create({
          data: { name: category.name, establishmentId: destId },
        });
        categoryIds.set(category.id, created.id);
      }

      const products = await tx.product.findMany({ where: { establishmentId: sourceId } });
      const productIds = new Map<string, string>();
      for (const product of products) {
        const categoryId = categoryIds.get(product.categoryId);
        if (!categoryId) continue;
        const created = await tx.product.create({
          data: {
            code: product.code,
            name: product.name,
            description: product.description,
            unit: product.unit,
            priceBuy: product.priceBuy,
            priceSell: product.priceSell,
            stockAlert: product.stockAlert,
            photoUrl: product.photoUrl,
            subcategory: product.subcategory,
            volume: product.volume,
            format: product.format,
            supplier: product.supplier,
            kind: product.kind,
            status: product.status,
            establishmentId: destId,
            categoryId,
          },
        });
        productIds.set(product.id, created.id);
      }

      const recipes = await tx.recipe.findMany({
        where: { establishmentId: sourceId },
        include: { items: true },
      });
      for (const recipe of recipes) {
        const productId = productIds.get(recipe.productId);
        if (!productId) continue;
        const created = await tx.recipe.create({
          data: { productId, establishmentId: destId },
        });
        for (const item of recipe.items) {
          const ingredientId = productIds.get(item.ingredientId);
          if (!ingredientId) continue;
          await tx.recipeItem.create({
            data: {
              recipeId: created.id,
              ingredientId,
              quantity: item.quantity,
              unit: item.unit,
            },
          });
        }
      }

      const lots = await tx.lot.findMany({
        where: { establishmentId: sourceId, qtyCurrent: { gt: 0 }, status: 'ACTIF' },
      });
      for (const lot of lots) {
        const productId = productIds.get(lot.productId);
        if (!productId) continue;
        await tx.lot.create({
          data: {
            number: lot.number,
            productId,
            establishmentId: destId,
            entryDate: lot.entryDate,
            expiryDate: lot.expiryDate,
            qtyInitial: lot.qtyCurrent,
            qtyCurrent: lot.qtyCurrent,
            priceBuy: lot.priceBuy,
            priceSell: lot.priceSell,
            location: lot.location,
            status: 'ACTIF',
          },
        });
      }

      const zones = await tx.deliveryZone.findMany({ where: { establishmentId: sourceId } });
      for (const zone of zones) {
        try {
          await tx.deliveryZone.create({
            data: {
              name: zone.name,
              code: zone.code,
              fee: zone.fee,
              status: zone.status,
              establishmentId: destId,
            },
          });
        } catch (error) {
          if (!(error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002')) {
            throw error;
          }
        }
      }
    });
  }
}
