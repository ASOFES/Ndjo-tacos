import { BadRequestException, Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma.service';

@Injectable()
export class StockService {
  constructor(private readonly prisma: PrismaService) {}

  async consumeFefo(params: {
    productId: string;
    establishmentId: string;
    quantity: number;
    userId: string;
    type: string;
    motif: string;
    destination: string;
    clientUuid?: string;
  }) {
    return this.prisma.$transaction((tx) => this.applyFefo(params, tx));
  }

  async applyFefo(
    params: {
      productId: string;
      establishmentId: string;
      quantity: number;
      userId: string;
      type: string;
      motif: string;
      destination: string;
      clientUuid?: string;
    },
    tx: Prisma.TransactionClient | PrismaService,
  ) {
    if (params.quantity <= 0) {
      throw new BadRequestException('Quantité invalide');
    }
    if (params.clientUuid) {
      const prior = await tx.stockMovement.findMany({
        where: { clientUuid: params.clientUuid },
        include: { lot: { select: { number: true, entryDate: true, priceBuy: true } } },
      });
      if (prior.length) {
        return prior.map((row) => ({
          number: row.lot?.number ?? row.number,
          quantity: row.quantity,
          entryDate: row.lot?.entryDate ?? null,
          priceBuy: row.lot?.priceBuy ?? 0,
        }));
      }
    }
    const lots = await tx.lot.findMany({
      where: {
        productId: params.productId,
        establishmentId: params.establishmentId,
        qtyCurrent: { gt: 0 },
        status: 'ACTIF',
      },
      orderBy: [{ expiryDate: 'asc' }, { createdAt: 'asc' }],
    });
    let remaining = params.quantity;
    const used: { number: string; quantity: number; entryDate: Date | null; priceBuy: number }[] = [];
    for (const lot of lots) {
      if (remaining <= 0) break;
      const take = Math.min(lot.qtyCurrent, remaining);
      const claimed = await tx.lot.updateMany({
        where: { id: lot.id, qtyCurrent: { gte: take } },
        data: { qtyCurrent: { decrement: take } },
      });
      if (claimed.count === 0) {
        throw new BadRequestException('Conflit de stock FEFO, réessayez');
      }
      const seq = await this.nextNumber(tx, `MOV-${params.type}`);
      await tx.stockMovement.create({
        data: {
          number: seq,
          type: params.type,
          quantity: take,
          motif: params.motif,
          destination: params.destination,
          productId: params.productId,
          lotId: lot.id,
          establishmentId: params.establishmentId,
          userId: params.userId,
          clientUuid: params.clientUuid,
        },
      });
      used.push({
        number: lot.number,
        quantity: take,
        entryDate: lot.entryDate,
        priceBuy: lot.priceBuy,
      });
      remaining -= take;
    }
    if (remaining > 0.0001) {
      throw new BadRequestException(
        `Stock insuffisant (FEFO). Demandé ${params.quantity}, manque ${remaining}.`,
      );
    }
    return used;
  }

  async consumeRecipe(params: {
    productId: string;
    establishmentId: string;
    portions: number;
    userId: string;
    orderNumber: string;
  }) {
    return this.prisma.$transaction((tx) => this.consumeRecipeTx(params, tx));
  }

  async consumeRecipeTx(
    params: {
      productId: string;
      establishmentId: string;
      portions: number;
      userId: string;
      orderNumber: string;
    },
    tx: Prisma.TransactionClient | PrismaService,
  ) {
    const recipe = await tx.recipe.findUnique({
      where: { productId: params.productId },
      include: { items: { include: { ingredient: true } } },
    });
    if (!recipe) {
      const lots = await tx.lot.count({
        where: {
          productId: params.productId,
          establishmentId: params.establishmentId,
          qtyCurrent: { gt: 0 },
        },
      });
      if (lots > 0) {
        return this.applyFefo(
          {
            productId: params.productId,
            establishmentId: params.establishmentId,
            quantity: params.portions,
            userId: params.userId,
            type: 'CONSOMMATION',
            motif: `CMD:${params.orderNumber}:${params.productId}`,
            destination: 'Cuisine',
          },
          tx,
        );
      }
      return [];
    }
    const used: { number: string; quantity: number; entryDate: Date | null; priceBuy: number }[] = [];
    for (const item of recipe.items) {
      const result = await this.applyFefo(
        {
          productId: item.ingredientId,
          establishmentId: params.establishmentId,
          quantity: item.quantity * params.portions,
          userId: params.userId,
          type: 'CONSOMMATION',
          motif: `CMD:${params.orderNumber}:${params.productId}`,
          destination: 'Cuisine',
        },
        tx,
      );
      used.push(...result);
    }
    return used;
  }

  async applyLotChange(
    params: {
      lotId: string;
      delta: number;
      type: string;
      motif: string;
      destination: string;
      userId: string;
    },
    tx: Prisma.TransactionClient | PrismaService = this.prisma,
  ) {
    const delta = Number(params.delta);
    if (!Number.isFinite(delta) || Math.abs(delta) < 0.0001) {
      return null;
    }
    const lot = await tx.lot.findUnique({
      where: { id: params.lotId },
      include: { product: true },
    });
    if (!lot) throw new BadRequestException('Lot introuvable');
    const oldQty = lot.qtyCurrent;
    const newQty = Math.round((oldQty + delta) * 1000) / 1000;
    if (newQty < -0.0001) {
      throw new BadRequestException(
        `Stock insuffisant sur ${lot.number} (actuel ${oldQty}, demandé ${Math.abs(delta)})`,
      );
    }
    const claimed = await tx.lot.updateMany({
      where:
        delta < 0
          ? { id: lot.id, qtyCurrent: { gte: Math.abs(delta) - 0.0001 } }
          : { id: lot.id, qtyCurrent: oldQty },
      data: { qtyCurrent: { increment: delta } },
    });
    if (claimed.count === 0) {
      throw new BadRequestException('Conflit de stock, réessayez');
    }
    const number = await this.nextNumber(tx, params.type === 'PERTE' ? 'PER' : 'INV');
    const movement = await tx.stockMovement.create({
      data: {
        number,
        type: params.type,
        quantity: delta,
        motif: params.motif,
        destination: params.destination,
        productId: lot.productId,
        lotId: lot.id,
        establishmentId: lot.establishmentId,
        userId: params.userId,
      },
    });
    await tx.auditLog.create({
      data: {
        userId: params.userId,
        action: params.type === 'PERTE' ? 'PERTE' : 'INVENTAIRE',
        entity: 'LOT',
        entityId: lot.id,
        details: `${lot.product.name} · ${lot.number} · ${oldQty} → ${newQty} · ${params.motif}`,
        oldValue: JSON.stringify({ lot: lot.number, qtyCurrent: oldQty }),
        newValue: JSON.stringify({ lot: lot.number, qtyCurrent: newQty, movement: number }),
        establishmentId: lot.establishmentId,
      },
    });
    return { lotId: lot.id, number: lot.number, oldQty, newQty, delta, movement };
  }

  async receiveLot(
    params: {
      productId: string;
      establishmentId: string;
      quantity: number;
      priceBuy: number;
      priceSell?: number;
      expiryDate?: string | Date | null;
      location?: string;
      motif?: string;
      userId: string;
      purchaseId?: string;
      supplierId?: string;
      clientUuid?: string;
    },
    tx: Prisma.TransactionClient | PrismaService = this.prisma,
  ) {
    if (params.clientUuid) {
      const existing = await tx.stockMovement.findFirst({
        where: { clientUuid: params.clientUuid },
        include: { lot: true },
      });
      if (existing?.lot) return existing.lot;
    }
    const product = await tx.product.findUnique({ where: { id: params.productId } });
    if (!product) throw new BadRequestException('Produit introuvable');
    if (product.establishmentId !== params.establishmentId) {
      throw new BadRequestException('Produit hors établissement');
    }
    const qty = Number(params.quantity);
    if (!Number.isFinite(qty) || qty <= 0) throw new BadRequestException('Quantité invalide');
    const seq = await this.nextNumber(tx, 'LOT');
    const prefix = product.code.replace(/[^A-Z0-9]/gi, '').slice(0, 6).toUpperCase();
    const lot = await tx.lot.create({
      data: {
        number: `${prefix}-${seq}`,
        productId: product.id,
        establishmentId: params.establishmentId,
        expiryDate: params.expiryDate ? new Date(params.expiryDate) : null,
        qtyInitial: qty,
        qtyCurrent: qty,
        priceBuy: Math.round(Number(params.priceBuy)),
        priceSell: Math.round(Number(params.priceSell ?? product.priceSell)),
        location: params.location?.trim() || 'Dépôt principal',
        purchaseId: params.purchaseId,
        supplierId: params.supplierId,
      },
      include: { product: true },
    });
    const movementNumber = await this.nextNumber(tx, 'ENT');
    await tx.stockMovement.create({
      data: {
        number: movementNumber,
        type: 'ENTREE',
        quantity: qty,
        motif: params.motif ?? 'Réception fournisseur',
        destination: lot.location,
        productId: product.id,
        lotId: lot.id,
        establishmentId: params.establishmentId,
        userId: params.userId,
        clientUuid: params.clientUuid,
      },
    });
    await tx.auditLog.create({
      data: {
        userId: params.userId,
        action: 'ENTREE',
        entity: 'LOT',
        entityId: lot.id,
        details: `Réception ${lot.number} · ${product.name} · ${qty} ${product.unit}`,
        newValue: JSON.stringify({
          lot: lot.number,
          qtyCurrent: qty,
          priceBuy: lot.priceBuy,
          purchaseId: params.purchaseId ?? null,
        }),
        establishmentId: params.establishmentId,
      },
    });
    return lot;
  }

  async nextNumber(tx: Prisma.TransactionClient | PrismaService, key: string) {
    const year = new Date().getFullYear();
    const sequenceKey = `${key}-${year}`;
    const existing = await tx.sequence.findUnique({ where: { key: sequenceKey } });
    const row = existing
      ? await tx.sequence.update({
          where: { key: sequenceKey },
          data: { value: { increment: 1 } },
        })
      : await tx.sequence.create({ data: { key: sequenceKey, value: 1 } });
    return `${key}-${year}-${String(row.value).padStart(6, '0')}`;
  }
}
