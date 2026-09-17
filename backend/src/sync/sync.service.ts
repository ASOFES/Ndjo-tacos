import { BadRequestException, HttpException, Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { OrdersService } from '../orders/orders.service';
import { StockService } from '../stock/stock.service';
import { DeliveryService } from '../delivery/delivery.service';
import { PaymentService } from '../payments/payment.service';
import { AuthedRequest } from '../auth/scope';

export type SyncOpInput = {
  clientUuid: string;
  type: string;
  payload: Record<string, unknown>;
};

export type SyncOpResult = {
  clientUuid: string;
  status: string;
  number?: string;
  id?: string;
  error?: string;
};

@Injectable()
export class SyncPushService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly orders: OrdersService,
    private readonly stock: StockService,
    private readonly delivery: DeliveryService,
    private readonly payments: PaymentService,
  ) {}

  async applyAll(
    operations: SyncOpInput[],
    req: AuthedRequest & { user: { sub: string; role: string; establishmentId?: string } },
  ) {
    const results: SyncOpResult[] = [];
    for (const operation of operations ?? []) {
      results.push(await this.applyOne(operation, req));
    }
    return { accepted: results.length, results };
  }

  private async applyOne(
    operation: SyncOpInput,
    req: AuthedRequest & { user: { sub: string; role: string; establishmentId?: string } },
  ): Promise<SyncOpResult> {
    const clientUuid = String(operation.clientUuid ?? '').trim();
    if (!clientUuid) {
      return { clientUuid: '', status: 'ECHEC', error: 'clientUuid obligatoire' };
    }
    const establishmentId =
      req.scopedEstablishmentId ||
      String(operation.payload.establishmentId ?? req.user.establishmentId ?? '');
    const existing = await this.prisma.syncOperation.findUnique({
      where: { clientUuid },
    });
    if (existing?.status === 'APPLIQUE') {
      const order = await this.prisma.order.findUnique({
        where: { clientUuid },
      });
      return {
        clientUuid,
        status: 'DEJA_APPLIQUE',
        number: order?.number,
        id: order?.id,
      };
    }
    if (existing?.status === 'REFUSE') {
      return {
        clientUuid,
        status: 'REFUSE',
        error: existing.error ?? 'Opération refusée',
      };
    }

    await this.prisma.syncOperation.upsert({
      where: { clientUuid },
      update: {
        status: 'EN_COURS',
        type: operation.type,
        payload: JSON.stringify(operation.payload),
      },
      create: {
        clientUuid,
        type: operation.type,
        payload: JSON.stringify(operation.payload),
        status: 'EN_COURS',
        userId: req.user.sub,
        establishmentId,
      },
    });

    try {
      const applied = await this.dispatch(operation, req, establishmentId, clientUuid);
      await this.prisma.syncOperation.update({
        where: { clientUuid },
        data: { status: 'APPLIQUE', appliedAt: new Date(), error: null },
      });
      return { clientUuid, status: 'APPLIQUE', ...applied };
    } catch (error) {
      const message = syncErrorText(error);
      const refuse = /stock insuffisant|conflit de stock|quantité invalide/i.test(
        message,
      );
      const status = refuse ? 'REFUSE' : 'ECHEC';
      await this.prisma.syncOperation.update({
        where: { clientUuid },
        data: { status, error: message },
      });
      await this.prisma.auditLog.create({
        data: {
          userId: req.user.sub,
          action: refuse ? 'REFUSER' : 'ECHEC',
          entity: 'SYNC',
          entityId: clientUuid,
          details: `${operation.type} · ${message}`,
          establishmentId,
          newValue: JSON.stringify({ type: operation.type, status }),
        },
      });
      return { clientUuid, status, error: message };
    }
  }

  private async dispatch(
    operation: SyncOpInput,
    req: AuthedRequest & { user: { sub: string; role: string } },
    establishmentId: string,
    clientUuid: string,
  ): Promise<{ number?: string; id?: string }> {
    const payload = operation.payload;
    switch (operation.type) {
      case 'ORDER':
        return this.applyOrder(payload, req.user.sub, establishmentId, clientUuid);
      case 'STOCK_EXIT':
        return this.applyStockExit(payload, req.user.sub, establishmentId, clientUuid);
      case 'STOCK_ENTRY':
        return this.applyStockEntry(payload, req.user.sub, establishmentId, clientUuid);
      case 'KITCHEN_STATUS':
        return this.applyKitchen(payload, req.user.sub, establishmentId);
      case 'DELIVERY_EVENT':
        return this.applyDelivery(payload, req);
      default:
        throw new BadRequestException(`Type sync inconnu: ${operation.type}`);
    }
  }

  private async applyOrder(
    payload: Record<string, unknown>,
    userId: string,
    establishmentId: string,
    clientUuid: string,
  ) {
    const existingOrder = await this.prisma.order.findUnique({
      where: { clientUuid },
    });
    if (existingOrder) {
      return { number: existingOrder.number, id: existingOrder.id };
    }
    const order = await this.orders.create(
      {
        establishmentId,
        clientUuid,
        type: String(payload.type ?? 'SUR_PLACE'),
        method: payload.method as string | undefined,
        customerId: payload.customerId as string | undefined,
        addressId: payload.addressId as string | undefined,
        zoneId: payload.zoneId as string | undefined,
        customerName: payload.customerName as string | undefined,
        customerPhone: payload.customerPhone as string | undefined,
        address: payload.address as string | undefined,
        zone: payload.zone as string | undefined,
        deliveryFee: payload.deliveryFee as number | undefined,
        items: (payload.items as { productId: string; quantity: number }[]) ?? [],
      },
      userId,
    );
    const method = String(payload.method ?? 'ESPECES');
    const type = String(payload.type ?? 'SUR_PLACE');
    if (method === 'ESPECES' && type !== 'LIVRAISON') {
      await this.payments.collectCash({
        orderId: order.id,
        userId,
        received: Number(payload.received ?? order.total),
        method: 'ESPECES',
      });
    }
    return { number: order.number, id: order.id };
  }

  private async applyStockExit(
    payload: Record<string, unknown>,
    userId: string,
    establishmentId: string,
    clientUuid: string,
  ) {
    const already = await this.prisma.syncOperation.findUnique({
      where: { clientUuid },
    });
    if (already?.status === 'APPLIQUE') return { number: already.id };
    const destination = String(payload.destination ?? 'Cuisine');
    const used = await this.stock.consumeFefo({
      productId: String(payload.productId),
      establishmentId,
      quantity: Number(payload.quantity),
      userId,
      type: String(payload.type ?? 'SORTIE'),
      motif: destination === 'Cuisine' ? `CUI:${payload.productId}` : String(payload.motif ?? 'Sortie hors ligne'),
      destination,
      clientUuid,
    });
    return { number: used[0]?.number, lots: used };
  }

  private async applyStockEntry(
    payload: Record<string, unknown>,
    userId: string,
    establishmentId: string,
    clientUuid: string,
  ) {
    const already = await this.prisma.syncOperation.findUnique({
      where: { clientUuid },
    });
    if (already?.status === 'APPLIQUE') return { number: already.id };
    const lot = await this.stock.receiveLot({
      productId: String(payload.productId),
      establishmentId,
      quantity: Number(payload.quantity),
      priceBuy: Number(payload.priceBuy ?? 0),
      expiryDate: (payload.expiryDate as string) ?? null,
      motif: String(payload.motif ?? 'Entrée hors ligne'),
      userId,
      clientUuid,
    });
    return { number: lot.number, id: lot.id };
  }

  private async applyKitchen(
    payload: Record<string, unknown>,
    userId: string,
    establishmentId: string,
  ) {
    const orderId = String(payload.orderId ?? '');
    let status = String(payload.status ?? '');
    const current = await this.prisma.order.findFirst({
      where: { OR: [{ id: orderId }, { clientUuid: orderId }] },
    });
    if (!current) throw new BadRequestException('Commande introuvable');
    if (current.establishmentId !== establishmentId) {
      throw new BadRequestException('Commande hors établissement');
    }
    const requested = status;
    if (current.status === status) {
      return { number: current.number, id: current.id };
    }
    if (status === 'NOUVELLE' && current.status === 'EN_CAISSE') {
      status = await this.orders.consumeCounterDrinks(current.id, userId);
    }
    if (
      (requested === 'EN_PREPARATION' || requested === 'PRETE') &&
      current.status !== 'EN_PREPARATION' &&
      current.status !== 'PRETE'
    ) {
      await this.orders.releaseToKitchen(current.id, userId);
    }
    const updated = await this.prisma.order.update({
      where: { id: current.id },
      data: { status },
    });
    await this.prisma.auditLog.create({
      data: {
        userId,
        action: 'STATUT',
        entity: 'COMMANDE',
        entityId: updated.id,
        details: `${updated.number} -> ${status} (sync)`,
        oldValue: current.status,
        newValue: status,
        establishmentId,
      },
    });
    return { number: updated.number, id: updated.id };
  }

  private async applyDelivery(
    payload: Record<string, unknown>,
    req: AuthedRequest & { user: { sub: string; role: string } },
  ) {
    const orderId = String(payload.orderId ?? '');
    const action = String(payload.action ?? '');
    const resolved =
      (await this.prisma.order.findFirst({
        where: { OR: [{ id: orderId }, { clientUuid: orderId }] },
        select: { id: true },
      }))?.id ?? orderId;
    const asReq = req;
    if (action === 'assign') {
      const order = await this.delivery.assign(resolved, payload.driverId as string | undefined, asReq);
      return { number: order.number, id: order.id };
    }
    if (action === 'start') {
      const order = await this.delivery.start(resolved, asReq);
      return { number: order.number, id: order.id };
    }
    if (action === 'arrive') {
      const order = await this.delivery.arrive(resolved, asReq);
      return { number: order.number, id: order.id };
    }
    if (action === 'deliver') {
      const order = await this.delivery.deliver(
        resolved,
        {
          otp: payload.otp as string | undefined,
          proofPhotoUrl: payload.proofPhotoUrl as string | undefined,
          proofSignature: payload.proofSignature as string | undefined,
          latitude: payload.latitude as number | undefined,
          longitude: payload.longitude as number | undefined,
        },
        asReq,
      );
      return { number: order.number, id: order.id };
    }
    if (action === 'location') {
      await this.delivery.recordLocation(
        {
          latitude: Number(payload.latitude),
          longitude: Number(payload.longitude),
          orderId: resolved,
        },
        req.user.sub,
      );
      return { id: resolved };
    }
    if (action === 'collect') {
      await this.payments.collectCash({
        orderId: resolved,
        userId: req.user.sub,
        received: Number(payload.received ?? 0),
        method: 'ESPECES',
      });
      return { id: resolved };
    }
    throw new BadRequestException(`Action livraison inconnue: ${action}`);
  }
}

function syncErrorText(error: unknown): string {
  if (error instanceof HttpException) {
    const response = error.getResponse();
    if (typeof response === 'string') return response;
    if (typeof response === 'object' && response && 'message' in response) {
      const message = (response as { message: unknown }).message;
      return Array.isArray(message) ? message.join(', ') : String(message);
    }
  }
  if (error instanceof Error) return error.message;
  return 'Échec de synchronisation';
}
