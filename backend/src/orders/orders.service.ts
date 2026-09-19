import { BadRequestException, Injectable } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { Prisma } from '@prisma/client';
import { PrismaService } from '../prisma.service';
import { StockService } from '../stock/stock.service';
import { WhatsAppService } from '../notifications/whatsapp.service';
import { CustomersService } from '../customers/customers.service';
import { createTrackingToken } from '../tracking/token';
import { resolveDiscount } from './discount.rules';
import * as bcrypt from 'bcryptjs';

export function isDrinkCategory(name?: string | null) {
  const normalized = (name ?? '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '');
  return normalized.includes('boisson');
}

/** Commandes cuisine : hors boissons seules, pour ne pas noyer le tableau (take) avec les PRETE caisse. */
export function kitchenBoardWhere(establishmentId: string): Prisma.OrderWhereInput {
  return {
    establishmentId,
    status: { in: ['NOUVELLE', 'EN_PREPARATION', 'PRETE'] },
    items: {
      some: {
        product: {
          category: {
            NOT: { name: { contains: 'boisson', mode: 'insensitive' } },
          },
        },
      },
    },
  };
}

export type StockShortage = {
  productId: string;
  name: string;
  dish: string;
  needed: number;
  available: number;
};

type SaleLine = { productId: string; quantity: number; name?: string };
type SaleProduct = Prisma.ProductGetPayload<{
  include: {
    category: true;
    recipe: { include: { items: { include: { ingredient: true } } } };
  };
}>;

function formatNeedQty(value: number) {
  const rounded = Math.round(value * 1000) / 1000;
  if (Math.abs(rounded - Math.round(rounded)) < 0.0001) return String(Math.round(rounded));
  return String(rounded);
}

const orderInclude = {
  items: true,
  payments: true,
  invoice: true,
  user: { select: { name: true } },
  driver: { select: { id: true, name: true, phone: true } },
  customer: { select: { id: true, name: true, phone: true, category: true } },
  discountApprovedBy: { select: { id: true, name: true, role: true } },
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
      discountPercent?: number;
      discountMotif?: string;
      approverUsername?: string;
      approverPassword?: string;
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

    const actor = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { role: true },
    });
    const fromClient = actor?.role === 'CLIENT';
    if (!fromClient) {
      await this.assertStockOrThrow(body.establishmentId, items);
    }

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

    let customerCategory = 'STANDARD';
    if (party.customerId) {
      const customer = await this.prisma.customer.findUnique({
        where: { id: party.customerId },
        select: { category: true },
      });
      customerCategory = customer?.category ?? 'STANDARD';
    }

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
      const subtotal = lines.reduce((sum, line) => sum + line.lineTotal, 0);
      let discountPercent = fromClient ? 0 : Number(body.discountPercent ?? 0);
      let discountAmount = 0;
      let discountMotif: string | null = null;
      let discountApprovedById: string | null = null;
      if (!fromClient && discountPercent > 0) {
        let resolved;
        try {
          resolved = resolveDiscount({
            category: customerCategory,
            percent: discountPercent,
            subtotal,
          });
        } catch (error) {
          throw new BadRequestException(
            error instanceof Error ? error.message : 'Remise invalide',
          );
        }
        discountPercent = resolved.percent;
        discountAmount = resolved.amount;
        discountMotif =
          String(body.discountMotif ?? resolved.category).toUpperCase() || resolved.category;
        if (resolved.needsApproval) {
          const approver = await this.assertDiscountApprover(
            body.approverUsername,
            body.approverPassword,
            userId,
          );
          discountApprovedById = approver.id;
        }
      }
      const total = Math.max(0, subtotal - discountAmount) + deliveryFee;
      const number = await this.stock.nextNumber(tx, 'NDJ');
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
          subtotal,
          discountPercent,
          discountAmount,
          discountMotif,
          discountApprovedById,
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
          details:
            discountAmount > 0
              ? `${created.number} · ${total} FC · remise ${discountPercent}% (−${discountAmount} FC) · ${created.type}`
              : `${created.number} · ${total} FC · ${created.type}`,
          newValue: JSON.stringify({
            number: created.number,
            total,
            subtotal,
            discountPercent,
            discountAmount,
            discountMotif,
          }),
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

  private async assertDiscountApprover(
    username?: string,
    password?: string,
    cashierId?: string,
  ) {
    const user = String(username ?? '').trim();
    const pass = String(password ?? '');
    if (!user || !pass) {
      throw new BadRequestException(
        'Remise au-delà du seuil auto : validation gestionnaire / admin requise (identifiants).',
      );
    }
    const approver = await this.prisma.user.findUnique({ where: { username: user } });
    if (!approver || !(await bcrypt.compare(pass, approver.passwordHash))) {
      throw new BadRequestException('Validation remise : identifiants incorrects');
    }
    if (approver.status !== 'ACTIF') {
      throw new BadRequestException('Validation remise : compte désactivé');
    }
    const allowed = ['SUPER_ADMIN', 'ADMIN', 'GESTIONNAIRE'].includes(approver.role);
    if (!allowed) {
      throw new BadRequestException('Validation remise : rôle insuffisant (gestionnaire ou admin)');
    }
    if (cashierId && approver.id === cashierId) {
      throw new BadRequestException('La validation doit être faite par un autre compte');
    }
    return approver;
  }

  formatShortages(shortages: StockShortage[], orderNumber?: string) {
    const prefix = orderNumber
      ? `Commande ${orderNumber} : produit en carence — `
      : 'Produit en carence — ';
    return (
      prefix +
      shortages
        .map((row) => {
          const qty = `besoin ${formatNeedQty(row.needed)}, stock ${formatNeedQty(row.available)}`;
          if (row.dish && row.dish !== row.name) {
            return `${row.dish} (${row.name} : ${qty})`;
          }
          return `${row.name} (${qty})`;
        })
        .join(' · ')
    );
  }

  async analyzeStock(
    establishmentId: string,
    lines: SaleLine[],
    tx: Prisma.TransactionClient | PrismaService = this.prisma,
  ) {
    const productIds = [...new Set(lines.map((line) => line.productId))];
    const products = await this.loadSaleCatalog(productIds, tx);
    const stockIds = this.stockProductIds(lines, products);
    const available = await this.stock.availableByProduct(establishmentId, stockIds, tx);
    return this.shortagesFromCatalog(lines, products, available);
  }

  async assertStockOrThrow(
    establishmentId: string,
    lines: SaleLine[],
    orderNumber?: string,
    tx: Prisma.TransactionClient | PrismaService = this.prisma,
  ) {
    const shortages = await this.analyzeStock(establishmentId, lines, tx);
    if (shortages.length) {
      throw new BadRequestException(this.formatShortages(shortages, orderNumber));
    }
    return shortages;
  }

  async withCashierStock<
    T extends {
      id: string;
      status: string;
      number: string;
      items: SaleLine[];
    },
  >(orders: T[], establishmentId: string) {
    const waiting = orders.filter((order) => order.status === 'EN_CAISSE');
    if (!waiting.length) return orders;
    const productIds = [
      ...new Set(waiting.flatMap((order) => order.items.map((item) => item.productId))),
    ];
    const products = await this.loadSaleCatalog(productIds);
    const stockIds = this.stockProductIds(
      waiting.flatMap((order) => order.items),
      products,
    );
    const available = await this.stock.availableByProduct(establishmentId, stockIds);
    return orders.map((order) => {
      if (order.status !== 'EN_CAISSE') return order;
      const shortages = this.shortagesFromCatalog(order.items, products, available);
      return {
        ...order,
        stockShortages: shortages,
        stockShortageMessage: shortages.length
          ? this.formatShortages(shortages, order.number)
          : '',
      };
    });
  }

  private async loadSaleCatalog(
    productIds: string[],
    tx: Prisma.TransactionClient | PrismaService = this.prisma,
  ) {
    if (!productIds.length) return new Map<string, SaleProduct>();
    const rows = await tx.product.findMany({
      where: { id: { in: productIds } },
      include: {
        category: true,
        recipe: { include: { items: { include: { ingredient: true } } } },
      },
    });
    return new Map(rows.map((row) => [row.id, row]));
  }

  private stockProductIds(lines: SaleLine[], products: Map<string, SaleProduct>) {
    const ids = new Set<string>();
    for (const line of lines) {
      const product = products.get(line.productId);
      if (!product) continue;
      if (isDrinkCategory(product.category?.name) || !product.recipe?.items?.length) {
        ids.add(product.id);
      } else {
        for (const item of product.recipe.items) ids.add(item.ingredientId);
      }
    }
    return [...ids];
  }

  private shortagesFromCatalog(
    lines: SaleLine[],
    products: Map<string, SaleProduct>,
    available: Map<string, number>,
  ): StockShortage[] {
    const needs: StockShortage[] = [];
    const add = (productId: string, name: string, dish: string, qty: number) => {
      const existing = needs.find((row) => row.productId === productId && row.dish === dish);
      if (existing) {
        existing.needed += qty;
        return;
      }
      needs.push({
        productId,
        name,
        dish,
        needed: qty,
        available: available.get(productId) ?? 0,
      });
    };
    for (const line of lines) {
      const product = products.get(line.productId);
      if (!product) continue;
      const qty = Number(line.quantity);
      const dish = product.name;
      if (isDrinkCategory(product.category?.name)) {
        add(product.id, product.name, dish, qty);
      } else if (product.recipe?.items?.length) {
        for (const item of product.recipe.items) {
          add(item.ingredientId, item.ingredient.name, dish, item.quantity * qty);
        }
      } else {
        add(product.id, product.name, dish, qty);
      }
    }
    return needs.filter((row) => row.available + 0.0001 < row.needed);
  }

  async consumeCounterDrinks(orderId: string, userId: string) {
    return this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findUnique({
        where: { id: orderId },
        include: { items: true },
      });
      if (!order) throw new BadRequestException('Commande introuvable');
      await this.assertStockOrThrow(order.establishmentId, order.items, order.number, tx);
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
