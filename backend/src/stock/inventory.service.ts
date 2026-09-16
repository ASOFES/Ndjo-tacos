import { BadRequestException, Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { StockService } from './stock.service';

const LOSS_MOTIFS = [
  'PERIME',
  'AVARIE',
  'ENDOMMAGE',
  'CASSE',
  'ERREUR',
  'AUTRE',
] as const;

const inventoryInclude = {
  countedBy: { select: { id: true, name: true, role: true } },
  validatedBy: { select: { id: true, name: true, role: true } },
  lines: {
    include: {
      product: { select: { id: true, name: true, code: true, unit: true } },
      lot: true,
      countedBy: { select: { id: true, name: true } },
    },
    orderBy: [{ product: { name: 'asc' as const } }, { lot: { expiryDate: 'asc' as const } }],
  },
};

const lossInclude = {
  product: { select: { id: true, name: true, code: true, unit: true } },
  lot: true,
  declaredBy: { select: { id: true, name: true, role: true } },
  validatedBy: { select: { id: true, name: true, role: true } },
};

function kindOf(variance: number | null | undefined) {
  if (variance == null || Math.abs(variance) < 0.0001) return 'AUCUN';
  return variance > 0 ? 'SURPLUS' : 'MANQUE';
}

function presentLine(line: any) {
  const variance =
    line.realQty == null ? null : Math.round((line.realQty - line.theoreticalQty) * 1000) / 1000;
  return {
    ...line,
    variance,
    kind: kindOf(variance),
  };
}

function presentInventory(session: any) {
  return {
    ...session,
    lines: (session.lines ?? []).map(presentLine),
    totals: {
      counted: (session.lines ?? []).filter((line: any) => line.realQty != null).length,
      lines: (session.lines ?? []).length,
      gaps: (session.lines ?? []).filter((line: any) => {
        if (line.realQty == null) return false;
        return Math.abs(line.realQty - line.theoreticalQty) >= 0.0001;
      }).length,
    },
  };
}

@Injectable()
export class InventoryService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly stock: StockService,
  ) {}

  listInventories(establishmentId: string) {
    return this.prisma.inventorySession
      .findMany({
        where: { establishmentId },
        include: inventoryInclude,
        orderBy: { createdAt: 'desc' },
        take: 40,
      })
      .then((rows) => rows.map(presentInventory));
  }

  async oneInventory(id: string) {
    const session = await this.prisma.inventorySession.findUnique({
      where: { id },
      include: inventoryInclude,
    });
    return session ? presentInventory(session) : null;
  }

  async start(body: {
    establishmentId: string;
    location?: string;
    notes?: string;
  }, userId: string) {
    const lots = await this.prisma.lot.findMany({
      where: { establishmentId: body.establishmentId, status: 'ACTIF' },
      include: { product: true },
      orderBy: [{ expiryDate: 'asc' }, { createdAt: 'asc' }],
    });
    if (!lots.length) throw new BadRequestException('Aucun lot actif à inventorier');
    const number = await this.stock.nextNumber(this.prisma, 'INV');
    const session = await this.prisma.inventorySession.create({
      data: {
        number,
        location: body.location?.trim() || 'Dépôt principal',
        notes: body.notes?.trim() || null,
        status: 'EN_COURS',
        establishmentId: body.establishmentId,
        countedById: userId,
        lines: {
          create: lots.map((lot) => ({
            productId: lot.productId,
            lotId: lot.id,
            unit: lot.product.unit,
            theoreticalQty: lot.qtyCurrent,
          })),
        },
      },
      include: inventoryInclude,
    });
    await this.prisma.auditLog.create({
      data: {
        userId,
        action: 'CREER',
        entity: 'INVENTAIRE',
        entityId: session.id,
        details: `${session.number} · ${lots.length} lots · ${session.location}`,
        establishmentId: body.establishmentId,
      },
    });
    return presentInventory(session);
  }

  async countLine(lineId: string, body: { realQty: number; note?: string }, userId: string) {
    const line = await this.prisma.inventoryLine.findUnique({
      where: { id: lineId },
      include: { inventory: true },
    });
    if (!line) throw new BadRequestException('Ligne introuvable');
    if (!['EN_COURS', 'SOUMIS'].includes(line.inventory.status)) {
      throw new BadRequestException('Cet inventaire n’est plus modifiable');
    }
    if (line.inventory.status === 'SOUMIS') {
      throw new BadRequestException('Inventaire soumis : attendez la validation ou rouvrez-le');
    }
    const realQty = Number(body.realQty);
    if (!Number.isFinite(realQty) || realQty < 0) {
      throw new BadRequestException('Quantité réelle invalide');
    }
    const variance = Math.round((realQty - line.theoreticalQty) * 1000) / 1000;
    const updated = await this.prisma.inventoryLine.update({
      where: { id: lineId },
      data: {
        realQty,
        variance,
        note: body.note?.trim() || null,
        countedById: userId,
        countedAt: new Date(),
      },
      include: inventoryInclude.lines.include,
    });
    return presentLine(updated);
  }

  async submit(id: string, userId: string) {
    const session = await this.mustOpen(id);
    if (session.status !== 'EN_COURS') throw new BadRequestException('Inventaire déjà soumis ou validé');
    const counted = session.lines.filter((line) => line.realQty != null);
    if (!counted.length) throw new BadRequestException('Saisissez au moins un comptage réel');
    const updated = await this.prisma.inventorySession.update({
      where: { id },
      data: { status: 'SOUMIS', submittedAt: new Date() },
      include: inventoryInclude,
    });
    await this.prisma.auditLog.create({
      data: {
        userId,
        action: 'SOUMETTRE',
        entity: 'INVENTAIRE',
        entityId: id,
        details: `${updated.number} soumis · ${counted.length} ligne(s) comptée(s)`,
        establishmentId: updated.establishmentId,
      },
    });
    return presentInventory(updated);
  }

  async validate(id: string, userId: string) {
    const session = await this.mustOpen(id);
    if (session.status === 'VALIDE') throw new BadRequestException('Inventaire déjà validé');
    if (session.status === 'ANNULE') throw new BadRequestException('Inventaire annulé');
    const counted = session.lines.filter((line) => line.realQty != null);
    if (!counted.length) throw new BadRequestException('Aucun comptage à valider');

    await this.prisma.$transaction(async (tx) => {
      for (const line of counted) {
        const lot = await tx.lot.findUnique({ where: { id: line.lotId } });
        if (!lot) throw new BadRequestException('Lot introuvable pendant la validation');
        const delta = Math.round((Number(line.realQty) - lot.qtyCurrent) * 1000) / 1000;
        const reported = Math.round((Number(line.realQty) - line.theoreticalQty) * 1000) / 1000;
        if (Math.abs(delta) < 0.0001) continue;
        const kind = kindOf(reported);
        await this.stock.applyLotChange(
          {
            lotId: line.lotId,
            delta,
            type: 'INVENTAIRE',
            motif: `Inventaire ${session.number} · ${kind} · théorique ${line.theoreticalQty} → réel ${line.realQty}${line.note ? ` · ${line.note}` : ''}`,
            destination: session.location,
            userId,
          },
          tx,
        );
      }
      await tx.inventorySession.update({
        where: { id },
        data: { status: 'VALIDE', validatedById: userId, validatedAt: new Date() },
      });
      await tx.auditLog.create({
        data: {
          userId,
          action: 'VALIDER',
          entity: 'INVENTAIRE',
          entityId: id,
          details: `${session.number} validé · ${counted.length} ligne(s)`,
          oldValue: JSON.stringify(
            counted.map((line) => ({ lotId: line.lotId, theoretical: line.theoreticalQty })),
          ),
          newValue: JSON.stringify(
            counted.map((line) => ({ lotId: line.lotId, real: line.realQty })),
          ),
          establishmentId: session.establishmentId,
        },
      });
    });
    return this.oneInventory(id);
  }

  listLosses(establishmentId: string) {
    return this.prisma.stockLoss.findMany({
      where: { establishmentId },
      include: lossInclude,
      orderBy: { declaredAt: 'desc' },
      take: 80,
    });
  }

  async declareLoss(body: {
    establishmentId: string;
    lotId: string;
    quantity: number;
    motif: string;
    note?: string;
    occurredAt?: string;
  }, userId: string) {
    const lot = await this.prisma.lot.findUnique({
      where: { id: body.lotId },
      include: { product: true },
    });
    if (!lot) throw new BadRequestException('Lot introuvable');
    if (lot.establishmentId !== body.establishmentId) {
      throw new BadRequestException('Lot hors établissement');
    }
    const quantity = Number(body.quantity);
    if (!Number.isFinite(quantity) || quantity <= 0) {
      throw new BadRequestException('Quantité de perte invalide');
    }
    const motif = String(body.motif ?? '').toUpperCase();
    if (!LOSS_MOTIFS.includes(motif as (typeof LOSS_MOTIFS)[number])) {
      throw new BadRequestException(`Motif invalide. Utilisez : ${LOSS_MOTIFS.join(', ')}`);
    }
    const number = await this.stock.nextNumber(this.prisma, 'PER');
    const loss = await this.prisma.stockLoss.create({
      data: {
        number,
        quantity,
        unit: lot.product.unit,
        motif,
        note: body.note?.trim() || null,
        occurredAt: body.occurredAt ? new Date(body.occurredAt) : new Date(),
        productId: lot.productId,
        lotId: lot.id,
        establishmentId: lot.establishmentId,
        declaredById: userId,
      },
      include: lossInclude,
    });
    await this.prisma.auditLog.create({
      data: {
        userId,
        action: 'CREER',
        entity: 'PERTE',
        entityId: loss.id,
        details: `${loss.number} · ${lot.product.name} · ${lot.number} · ${quantity} ${lot.product.unit} · ${motif}`,
        newValue: JSON.stringify({ lot: lot.number, quantity, motif }),
        establishmentId: lot.establishmentId,
      },
    });
    return loss;
  }

  async validateLoss(id: string, userId: string) {
    const loss = await this.prisma.stockLoss.findUnique({
      where: { id },
      include: { lot: true, product: true },
    });
    if (!loss) throw new BadRequestException('Perte introuvable');
    if (loss.status === 'VALIDEE') throw new BadRequestException('Perte déjà validée');
    if (loss.status === 'REFUSEE') throw new BadRequestException('Perte refusée');

    await this.prisma.$transaction(async (tx) => {
      const applied = await this.stock.applyLotChange(
        {
          lotId: loss.lotId,
          delta: -loss.quantity,
          type: 'PERTE',
          motif: `${loss.motif}${loss.note ? ` · ${loss.note}` : ''}`,
          destination: 'Pertes',
          userId,
        },
        tx,
      );
      await tx.stockLoss.update({
        where: { id },
        data: {
          status: 'VALIDEE',
          validatedById: userId,
          validatedAt: new Date(),
          movementId: applied?.movement.id,
        },
      });
      await tx.auditLog.create({
        data: {
          userId,
          action: 'VALIDER',
          entity: 'PERTE',
          entityId: id,
          details: `${loss.number} validée · ${loss.product.name} · ${loss.lot.number} · -${loss.quantity} ${loss.unit}`,
          oldValue: JSON.stringify({ qtyCurrent: applied?.oldQty }),
          newValue: JSON.stringify({ qtyCurrent: applied?.newQty, movement: applied?.movement.number }),
          establishmentId: loss.establishmentId,
        },
      });
    });
    return this.prisma.stockLoss.findUnique({ where: { id }, include: lossInclude });
  }

  private async mustOpen(id: string) {
    const session = await this.prisma.inventorySession.findUnique({
      where: { id },
      include: { lines: true },
    });
    if (!session) throw new BadRequestException('Inventaire introuvable');
    return session;
  }
}

export { LOSS_MOTIFS };
