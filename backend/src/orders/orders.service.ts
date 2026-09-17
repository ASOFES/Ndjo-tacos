import { BadRequestException, Injectable } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma.service';
import { StockService } from '../stock/stock.service';
import { WhatsAppService } from '../notifications/whatsapp.service';
import { CustomersService } from '../customers/customers.service';
import { createTrackingToken } from '../tracking/token';

export function isDrinkCategory(name?: string | null) {
  const normalized = (name ?? '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '');
  return normalized.includes('boisson');
}

const orderInclude = {
  items: true,
  payments: true,
  invoice: true,
  user: { select: { name: true } },
  driver: { select: { id: true, name: true, phone: true } },
  customer: { select: { id: true, name: true, phone: true } },
  deliveryAddress: { include: { zone: true } },
  deliveryZone: true,
};

@Injectable()
export class OrdersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly stock: StockService,
    private readonly whatsapp: WhatsAppService,
    private readonly customers: CustomersService,
  ) {}

  async create(
    body: {
      clientUuid?: string;
      establishmentId: string;
      type?: string;
      method?: string;
      customerId?: string;
      addressId?: string;
      zoneId?: string;
      customerName?: string;
      customerPhone?: string;
      address?: string;
      zone?: string;
      deliveryFee?: number;
      items: { productId: string; quantity: number }[];
    },
    userId: string,
  ) {
    if (body.clientUuid) {
      const existing = await this.prisma.order.findUnique({
        where: { clientUuid: body.clientUuid },
        include: orderInclude,
      });
      if (existing) return existing;
    }
    const items = body.items ?? [];
    if (!String(body.establishmentId ?? '').trim()) {
      throw new BadRequestException('Choisissez un établissement');
    }
    if (!items.length) throw new BadRequestException('Panier vide');

    if (body.customerName && body.customerPhone) {
      await this.customers.ensureCustomer({
        establishmentId: body.establishmentId,
        name: body.customerName,
        phone: body.customerPhone,
      });
    }
    const party = await this.customers.resolveDelivery({
      establishmentId: body.establishmentId,
      type: body.type,
      customerId: body.customerId,
      addressId: body.addressId,
      zoneId: body.zoneId,
      customerName: body.customerName,
      customerPhone: body.customerPhone,
      address: body.address,
      zone: body.zone,
    });

    const order = await this.prisma.$transaction(async (tx) => {
      const products = await tx.product.findMany({
        where: { id: { in: items.map((item) => item.productId) } },
        include: { category: true },
      });
      const drinkIds = new Set(
        products.filter((row) => isDrinkCategory(row.category?.name)).map((row) => row.id),
      );
      const lines = items.map((item) => {
        const product = products.find((row) => row.id === item.productId);
        if (!product) throw new BadRequestException('Produit introuvable');
        if (product.establishmentId !== body.establishmentId) {
          throw new BadRequestException('Produit hors établissement');
        }
        return {
          productId: product.id,
          name: product.name,
          quantity: Number(item.quantity),
          unitPrice: product.priceSell,
          lineTotal: product.priceSell * Number(item.quantity),
        };
      });
      const deliveryFee = party.deliveryFee;
      const total =
        lines.reduce((sum, line) => sum + line.lineTotal, 0) + deliveryFee;
      const number = await this.stock.nextNumber(tx, 'NDJ');
      const actor = await this.prisma.user.findUnique({
        where: { id: userId },
        select: { role: true },
      });
      const fromClient = actor?.role === 'CLIENT';
      const hasKitchen = lines.some((line) => !drinkIds.has(line.productId));
      const created = await tx.order.create({
        data: {
          clientUuid: body.clientUuid ?? randomUUID(),
          number,
          type: body.type ?? 'SUR_PLACE',
          status: fromClient ? 'EN_CAISSE' : hasKitchen ? 'NOUVELLE' : 'PRETE',
          paymentStatus: 'EN_ATTENTE',
          customerId: party.customerId,
          addressId: party.addressId,
          zoneId: party.zoneId,
          customerName: party.customerName,
          customerPhone: party.customerPhone,
          address: party.address,
          zone: party.zone,
          deliveryFee,
          total,
          otp: String(Math.floor(1000 + Math.random() * 9000)),
          trackingToken: createTrackingToken(),
          establishmentId: body.establishmentId,
          userId,
          items: { create: lines },
        },
        include: orderInclude,
      });
      if ((body.type ?? 'SUR_PLACE') === 'LIVRAISON') {
        const method = body.method ?? 'ESPECES';
        if (method === 'ESPECES' || method === 'CASH' || method === 'COD') {
          await tx.payment.create({
            data: {
              orderId: created.id,
              method: 'ESPECES',
              status: 'EN_ATTENTE',
              amount: total,
              received: 0,
              changeDue: 0,
              provider: 'CASH',
              userId,
            },
          });
        }
      }
      if (!fromClient) {
        await this.consumeDrinkLinesTx(tx, {
          orderNumber: created.number,
          establishmentId: body.establishmentId,
          userId,
          lines: lines.filter((line) => drinkIds.has(line.productId)),
        });
      }
      await tx.auditLog.create({
        data: {
          userId,
          action: 'CREER',
          entity: 'COMMANDE',
          entityId: created.id,
          details: `${created.number} · ${total} FC · ${created.type}`,
          newValue: JSON.stringify({ number: created.number, total }),
          establishmentId: body.establishmentId,
        },
      });
      return created;
    });

    if (order.status !== 'EN_CAISSE') {
      const publicBase = process.env.PUBLIC_BASE_URL ?? 'http://localhost:3000';
      await this.whatsapp.notify({
        orderId: order.id,
        event: 'COMMANDE_CONFIRMEE',
        title: 'Commande confirmée',
        message: `Votre commande #${order.number} a été confirmée. Suivi : ${publicBase}/track/${order.trackingToken}`,
        phone: order.customerPhone,
      });
    }
    return order;
  }

  async consumeCounterDrinks(orderId: string, userId: string) {
    return this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findUnique({
        where: { id: orderId },
        include: { items: true },
      });
      if (!order) throw new BadRequestException('Commande introuvable');
      const products = await tx.product.findMany({
        where: { id: { in: order.items.map((item) => item.productId) } },
        include: { category: true },
      });
      const drinkIds = new Set(
        products.filter((row) => isDrinkCategory(row.category?.name)).map((row) => row.id),
      );
      await this.consumeDrinkLinesTx(tx, {
        orderNumber: order.number,
        establishmentId: order.establishmentId,
        userId,
        lines: order.items.filter((line) => drinkIds.has(line.productId)),
      });
      const hasKitchen = order.items.some((line) => !drinkIds.has(line.productId));
      return hasKitchen ? 'NOUVELLE' : 'PRETE';
    });
  }

  private async consumeDrinkLinesTx(
    tx: Prisma.TransactionClient | PrismaService,
    params: {
      orderNumber: string;
      establishmentId: string;
      userId: string;
      lines: { productId: string; quantity: number }[];
    },
  ) {
    for (const line of params.lines) {
      const already = await tx.stockMovement.findFirst({
        where: {
          establishmentId: params.establishmentId,
          motif: `CMD:${params.orderNumber}:${line.productId}`,
          destination: 'Caisse',
        },
      });
      if (already) continue;
      await this.stock.applyFefo(
        {
          productId: line.productId,
          establishmentId: params.establishmentId,
          quantity: line.quantity,
          userId: params.userId,
          type: 'VENTE',
          motif: `CMD:${params.orderNumber}:${line.productId}`,
          destination: 'Caisse',
        },
        tx,
      );
    }
  }

  async releaseToKitchen(orderId: string, userId: string) {
    return this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findUnique({
        where: { id: orderId },
        include: { items: true },
      });
      if (!order) throw new BadRequestException('Commande introuvable');
      const products = await tx.product.findMany({
        where: { id: { in: order.items.map((item) => item.productId) } },
        include: { category: true },
      });
      const drinkIds = new Set(
        products.filter((row) => isDrinkCategory(row.category?.name)).map((row) => row.id),
      );
      const kitchenLines = order.items.filter((line) => !drinkIds.has(line.productId));
      if (kitchenLines.length === 0) return order;
      const already = await tx.stockMovement.findFirst({
        where: {
          establishmentId: order.establishmentId,
          destination: 'Cuisine',
          motif: { startsWith: `CMD:${order.number}:` },
        },
      });
      if (already) return order;
      for (const line of kitchenLines) {
        await this.stock.consumeRecipeTx(
          {
            productId: line.productId,
            establishmentId: order.establishmentId,
            portions: line.quantity,
            userId,
            orderNumber: order.number,
          },
          tx,
        );
      }
      return order;
    });
  }
}
