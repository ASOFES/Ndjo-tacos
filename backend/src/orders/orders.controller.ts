import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Param,
  Post,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { PaymentService } from '../payments/payment.service';
import { OrdersService, isDrinkCategory, kitchenBoardWhere } from './orders.service';
import { WhatsAppService } from '../notifications/whatsapp.service';
import { TrackingGateway } from '../tracking/tracking.gateway';
import { assertSameEstablishment, AuthedRequest, mustExist } from '../auth/scope';

@Controller('orders')
@UseGuards(JwtGuard, AccessGuard)
export class OrdersController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly payments: PaymentService,
    private readonly orders: OrdersService,
    private readonly whatsapp: WhatsAppService,
    private readonly live: TrackingGateway,
  ) {}

  @Get()
  @RequirePermission('commandes.voir', 'cuisine.voir', 'ventes.voir')
  async list(
    @Query('establishmentId') establishmentId: string,
    @Query('kitchen') kitchen?: string,
  ) {
    const orders = await this.prisma.order.findMany({
      where:
        kitchen === '1'
          ? kitchenBoardWhere(establishmentId)
          : { establishmentId },
      include: {
        items: true,
        payments: true,
        invoice: true,
        driver: { select: { name: true, phone: true } },
        user: { select: { name: true } },
        customer: { select: { id: true, name: true, phone: true } },
        deliveryZone: true,
      },
      orderBy: kitchen === '1' ? { updatedAt: 'desc' } : { createdAt: 'desc' },
      take: kitchen === '1' ? 200 : 80,
    });
    if (kitchen !== '1') {
      return this.orders.withCashierStock(orders, establishmentId);
    }
    if (orders.length === 0) return orders;
    const productIds = [
      ...new Set(orders.flatMap((order) => order.items.map((item) => item.productId))),
    ];
    const products = await this.prisma.product.findMany({
      where: { id: { in: productIds } },
      include: { category: true },
    });
    const drinkIds = new Set(
      products.filter((row) => isDrinkCategory(row.category?.name)).map((row) => row.id),
    );
    const kitchenOrders = orders.filter((order) =>
      order.items.some((item) => !drinkIds.has(item.productId)),
    );
    if (kitchenOrders.length === 0) return [];
    const recipes = await this.prisma.recipe.findMany({
      where: { productId: { in: productIds.filter((id) => !drinkIds.has(id)) } },
      include: { items: { include: { ingredient: { select: { name: true, unit: true } } } } },
    });
    const recipeByProduct = new Map(recipes.map((recipe) => [recipe.productId, recipe]));
    const movements = await this.prisma.stockMovement.findMany({
      where: {
        establishmentId,
        type: { in: ['CONSOMMATION', 'VENTE'] },
        destination: 'Cuisine',
        OR: kitchenOrders.map((order) => ({ motif: { startsWith: `CMD:${order.number}:` } })),
      },
      include: {
        product: { select: { name: true, unit: true } },
        lot: { select: { number: true, entryDate: true } },
      },
      orderBy: { createdAt: 'asc' },
    });
    const byOrder = new Map<string, typeof movements>();
    for (const move of movements) {
      const match = /^CMD:([^:]+):/.exec(move.motif ?? '');
      if (!match) continue;
      const list = byOrder.get(match[1]) ?? [];
      list.push(move);
      byOrder.set(match[1], list);
    }
    return kitchenOrders.map((order) => {
      const kitchenItems = order.items.filter((item) => !drinkIds.has(item.productId));
      return {
        id: order.id,
        number: order.number,
        status: order.status,
        type: order.type,
        createdAt: order.createdAt,
        user: order.user,
        customer: order.customer,
        items: kitchenItems.map((item) => ({
          id: item.id,
          productId: item.productId,
          name: item.name,
          quantity: item.quantity,
        })),
        kitchenFoods: kitchenItems.map((item) => {
          const recipe = recipeByProduct.get(item.productId);
          return {
            name: item.name,
            quantity: item.quantity,
            foods: recipe
              ? recipe.items.map((row) => ({
                  name: row.ingredient.name,
                  quantity: row.quantity * item.quantity,
                  unit: row.ingredient.unit,
                }))
              : [{ name: item.name, quantity: item.quantity, unit: '' }],
          };
        }),
        consumedLots: (byOrder.get(order.number) ?? []).map((move) => ({
          product: move.product.name,
          unit: move.product.unit,
          lot: move.lot?.number ?? '—',
          quantity: move.quantity,
          entryDate: move.lot?.entryDate?.toISOString().split('T')[0] ?? null,
        })),
      };
    });
  }

  @Get('invoices')
  @RequirePermission('factures.voir', 'ventes.voir')
  invoices(@Query('establishmentId') establishmentId: string) {
    return this.prisma.invoice.findMany({
      where: { order: { establishmentId } },
      include: {
        order: {
          include: {
            items: true,
            customer: { select: { id: true, name: true, phone: true } },
            establishment: { select: { name: true, phone: true, address: true } },
          },
        },
      },
      orderBy: { createdAt: 'desc' },
    });
  }

  @Post()
  @RequirePermission('ventes.creer', 'commandes.creer')
  create(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    return this.orders.create(
      {
        ...body,
        establishmentId:
          req.scopedEstablishmentId ?? body.establishmentId,
      },
      req.user.sub,
    );
  }

  @Post(':id/pay')
  @RequirePermission('ventes.creer')
  async pay(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const current = mustExist(
      await this.prisma.order.findUnique({ where: { id } }),
      'Commande introuvable',
    );
    assertSameEstablishment(current.establishmentId, req);
    return this.payments.initiate({
      orderId: id,
      userId: req.user.sub,
      received: Number(body.received ?? body.amount ?? 0),
      method: body.method ?? 'ESPECES',
      phone: body.phone,
    });
  }

  @Post(':id/status')
  @RequirePermission('cuisine.statut', 'commandes.voir')
  async status(
    @Param('id') id: string,
    @Body() body: { status: string },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const allowed = [
      'EN_CAISSE',
      'NOUVELLE',
      'EN_PREPARATION',
      'PRETE',
      'SERVIE',
      'PAYEE',
      'ANNULEE',
      'EN_LIVRAISON',
      'LIVREE',
    ];
    if (!allowed.includes(body.status)) throw new BadRequestException('Statut invalide');
    const current = mustExist(
      await this.prisma.order.findUnique({ where: { id } }),
      'Commande introuvable',
    );
    assertSameEstablishment(current.establishmentId, req);
    const requested = body.status;
    let nextStatus = requested;
    if (requested === 'NOUVELLE' && current.status === 'EN_CAISSE') {
      nextStatus = await this.orders.consumeCounterDrinks(id, req.user.sub);
    }
    if (
      (requested === 'EN_PREPARATION' || requested === 'PRETE') &&
      current.status !== 'EN_PREPARATION' &&
      current.status !== 'PRETE'
    ) {
      await this.orders.releaseToKitchen(id, req.user.sub);
    }
    const order = await this.prisma.order.update({
      where: { id },
      data: { status: nextStatus },
      include: { items: true, payments: true, user: { select: { name: true } } },
    });
    if (nextStatus === 'NOUVELLE' && current.status === 'EN_CAISSE') {
      const publicBase = process.env.PUBLIC_BASE_URL ?? 'http://localhost:3000';
      await this.whatsapp.notify({
        orderId: order.id,
        event: 'COMMANDE_CONFIRMEE',
        title: 'Commande confirmée',
        message: `Votre commande #${order.number} a été envoyée en cuisine. Suivi : ${publicBase}/track/${order.trackingToken}`,
        phone: order.customerPhone,
      });
    }
    if (nextStatus === 'EN_PREPARATION' || nextStatus === 'PRETE') {
      await this.whatsapp.notify({
        orderId: order.id,
        event: nextStatus === 'PRETE' ? 'PRETE' : 'EN_PREPARATION',
        title: nextStatus === 'PRETE' ? 'Commande prête' : 'Commande en préparation',
        message:
          nextStatus === 'PRETE'
            ? `Votre commande #${order.number} est prête.`
            : `Votre commande #${order.number} est en préparation.`,
        phone: order.customerPhone,
      });
    }
    if (order.trackingToken) {
      this.live.emitStatus(order.trackingToken, {
        number: order.number,
        status: order.status,
      });
    }
    await this.prisma.auditLog.create({
      data: {
        userId: req.user.sub,
        action: 'STATUT',
        entity: 'COMMANDE',
        entityId: order.id,
        details: `${order.number} → ${order.status}`,
        oldValue: current.status,
        newValue: order.status,
        establishmentId: order.establishmentId,
      },
    });
    return order;
  }
}
