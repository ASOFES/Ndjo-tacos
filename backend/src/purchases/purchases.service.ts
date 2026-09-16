import { BadRequestException, Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { StockService } from '../stock/stock.service';

const supplierInclude = { _count: { select: { purchases: true, lots: true } } };
const purchaseInclude = {
  supplier: true,
  createdBy: { select: { id: true, name: true } },
  lines: { include: { product: { select: { id: true, name: true, code: true, unit: true } } } },
  lots: { include: { product: { select: { name: true, code: true } } } },
};

@Injectable()
export class PurchasesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly stock: StockService,
  ) {}

  listSuppliers(establishmentId: string) {
    return this.prisma.supplier.findMany({
      where: { establishmentId },
      include: supplierInclude,
      orderBy: { name: 'asc' },
    });
  }

  async createSupplier(body: {
    establishmentId: string;
    name: string;
    phone?: string;
    email?: string;
    address?: string;
    status?: string;
    notes?: string;
  }, userId: string) {
    const name = String(body.name ?? '').trim();
    if (!name) throw new BadRequestException('Nom du fournisseur obligatoire');
    try {
      const supplier = await this.prisma.supplier.create({
        data: {
          name,
          phone: body.phone?.trim() || null,
          email: body.email?.trim() || null,
          address: body.address?.trim() || null,
          status: body.status ?? 'ACTIF',
          notes: body.notes?.trim() || null,
          establishmentId: body.establishmentId,
        },
        include: supplierInclude,
      });
      await this.audit(userId, 'CREER', 'FOURNISSEUR', supplier.id, supplier.name, body.establishmentId);
      return supplier;
    } catch {
      throw new BadRequestException('Ce fournisseur existe déjà dans l’établissement');
    }
  }

  async updateSupplier(id: string, body: {
    name?: string;
    phone?: string | null;
    email?: string | null;
    address?: string | null;
    status?: string;
    notes?: string | null;
  }, userId: string) {
    const before = await this.prisma.supplier.findUnique({ where: { id } });
    if (!before) throw new BadRequestException('Fournisseur introuvable');
    const supplier = await this.prisma.supplier.update({
      where: { id },
      data: {
        name: body.name?.trim() || before.name,
        phone: body.phone === undefined ? before.phone : body.phone?.trim() || null,
        email: body.email === undefined ? before.email : body.email?.trim() || null,
        address: body.address === undefined ? before.address : body.address?.trim() || null,
        status: body.status ?? before.status,
        notes: body.notes === undefined ? before.notes : body.notes?.trim() || null,
      },
      include: supplierInclude,
    });
    await this.audit(userId, 'MODIFIER', 'FOURNISSEUR', id, supplier.name, before.establishmentId);
    return supplier;
  }

  listPurchases(establishmentId: string) {
    return this.prisma.purchase.findMany({
      where: { establishmentId },
      include: purchaseInclude,
      orderBy: { createdAt: 'desc' },
    });
  }

  onePurchase(id: string) {
    return this.prisma.purchase.findUnique({
      where: { id },
      include: purchaseInclude,
    });
  }

  async createPurchase(body: {
    establishmentId: string;
    supplierId: string;
    notes?: string;
    location?: string;
    orderedAt?: string;
    lines: { productId: string; quantity: number; unitPrice?: number }[];
  }, userId: string) {
    const supplier = await this.prisma.supplier.findUnique({ where: { id: body.supplierId } });
    if (!supplier || supplier.establishmentId !== body.establishmentId) {
      throw new BadRequestException('Fournisseur hors établissement');
    }
    if (supplier.status !== 'ACTIF') throw new BadRequestException('Fournisseur inactif');
    const lines = body.lines ?? [];
    if (!lines.length) throw new BadRequestException('Ajoutez au moins une ligne d’achat');

    const products = await this.prisma.product.findMany({
      where: { id: { in: lines.map((line) => line.productId) } },
    });
    const prepared = lines.map((line) => {
      const product = products.find((row) => row.id === line.productId);
      if (!product || product.establishmentId !== body.establishmentId) {
        throw new BadRequestException('Produit hors établissement');
      }
      const quantity = Number(line.quantity);
      const unitPrice = Math.round(Number(line.unitPrice ?? product.priceBuy));
      if (!Number.isFinite(quantity) || quantity <= 0) throw new BadRequestException('Quantité invalide');
      return {
        productId: product.id,
        quantity,
        receivedQty: 0,
        unit: product.unit,
        unitPrice,
        lineTotal: Math.round(quantity * unitPrice),
      };
    });
    const total = prepared.reduce((sum, line) => sum + line.lineTotal, 0);
    const number = await this.stock.nextNumber(this.prisma, 'ACH');
    const purchase = await this.prisma.purchase.create({
      data: {
        number,
        status: 'COMMANDE',
        notes: body.notes?.trim() || null,
        location: body.location?.trim() || 'Dépôt principal',
        total,
        orderedAt: body.orderedAt ? new Date(body.orderedAt) : new Date(),
        supplierId: supplier.id,
        establishmentId: body.establishmentId,
        createdById: userId,
        lines: { create: prepared },
      },
      include: purchaseInclude,
    });
    await this.audit(
      userId,
      'CREER',
      'ACHAT',
      purchase.id,
      `${purchase.number} · ${supplier.name} · ${total} FC`,
      body.establishmentId,
      JSON.stringify({ total, lines: prepared.length }),
    );
    return purchase;
  }

  async receive(id: string, body: {
    location?: string;
    lines: { lineId: string; quantity: number; expiryDate?: string; priceBuy?: number }[];
  }, userId: string) {
    const purchase = await this.prisma.purchase.findUnique({
      where: { id },
      include: { lines: { include: { product: true } }, supplier: true },
    });
    if (!purchase) throw new BadRequestException('Bon d’achat introuvable');
    if (purchase.status === 'ANNULE') throw new BadRequestException('Achat annulé');
    if (purchase.status === 'RECU') throw new BadRequestException('Achat déjà entièrement reçu');
    const incoming = body.lines ?? [];
    if (!incoming.length) throw new BadRequestException('Aucune ligne à réceptionner');

    const lots = await this.prisma.$transaction(async (tx) => {
      const created: { number: string; qtyCurrent: number }[] = [];
      for (const item of incoming) {
        const line = purchase.lines.find((row) => row.id === item.lineId);
        if (!line) throw new BadRequestException('Ligne d’achat introuvable');
        const qty = Number(item.quantity);
        const remaining = line.quantity - line.receivedQty;
        if (!Number.isFinite(qty) || qty <= 0) throw new BadRequestException('Quantité reçue invalide');
        if (qty - remaining > 0.0001) {
          throw new BadRequestException(
            `Quantité reçue trop élevée pour ${line.product.name} (reste ${remaining})`,
          );
        }
        const lot = await this.stock.receiveLot(
          {
            productId: line.productId,
            establishmentId: purchase.establishmentId,
            quantity: qty,
            priceBuy: Number(item.priceBuy ?? line.unitPrice),
            expiryDate: item.expiryDate,
            location: body.location || purchase.location,
            motif: `Réception ${purchase.number} · ${purchase.supplier.name}`,
            userId,
            purchaseId: purchase.id,
            supplierId: purchase.supplierId,
          },
          tx,
        );
        await tx.purchaseLine.update({
          where: { id: line.id },
          data: { receivedQty: { increment: qty } },
        });
        created.push(lot);
      }
      const fresh = await tx.purchaseLine.findMany({ where: { purchaseId: id } });
      const complete = fresh.every((line) => line.receivedQty + 0.0001 >= line.quantity);
      await tx.purchase.update({
        where: { id },
        data: {
          status: complete ? 'RECU' : 'PARTIEL',
          receivedAt: complete ? new Date() : purchase.receivedAt,
          location: body.location?.trim() || purchase.location,
        },
      });
      return created;
    });

    await this.audit(
      userId,
      'RECEPTION',
      'ACHAT',
      id,
      `${purchase.number} · ${lots.length} lot(s)`,
      purchase.establishmentId,
      JSON.stringify(lots.map((lot) => ({ number: lot.number, qty: lot.qtyCurrent }))),
    );
    return this.onePurchase(id);
  }

  private audit(
    userId: string,
    action: string,
    entity: string,
    entityId: string,
    details: string,
    establishmentId: string,
    newValue?: string,
  ) {
    return this.prisma.auditLog.create({
      data: { userId, action, entity, entityId, details, establishmentId, newValue },
    });
  }
}
