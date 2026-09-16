import { BadRequestException, Injectable } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { PrismaService } from '../prisma.service';
import { InvoiceService } from '../invoices/invoice.service';
import { WhatsAppService } from '../notifications/whatsapp.service';
import { FlexPayAdapter } from './flexpay.adapter';
import { StripeAdapter } from './stripe.adapter';

@Injectable()
export class PaymentService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly invoices: InvoiceService,
    private readonly whatsapp: WhatsAppService,
    private readonly flexpay: FlexPayAdapter,
    private readonly stripe: StripeAdapter,
  ) {}

  operatorConfigured(method: string) {
    if (method === 'MOBILE_MONEY') return this.flexpay.configured();
    if (method === 'CARTE') return this.flexpay.configured() || this.stripe.configured();
    if (method === 'VIREMENT') return true;
    return true;
  }

  async initiate(params: {
    orderId: string;
    userId: string;
    method: string;
    received?: number;
    phone?: string;
  }) {
    const order = await this.prisma.order.findUnique({
      where: { id: params.orderId },
      include: { items: true, payments: true, invoice: true },
    });
    if (!order) throw new BadRequestException('Commande introuvable');
    if (order.paymentStatus === 'PAYE') return order;

    const method = params.method ?? 'ESPECES';
    if (method === 'ESPECES' || method === 'CASH') {
      return this.collectCash({
        orderId: order.id,
        userId: params.userId,
        received: Number(params.received ?? 0),
        method: 'ESPECES',
      });
    }
    if (method === 'MOBILE_MONEY') return this.startMobileMoney(order, params);
    if (method === 'CARTE') return this.startCard(order, params);
    if (method === 'VIREMENT') return this.startTransfer(order, params);
    throw new BadRequestException('Mode de paiement inconnu');
  }

  async collectCash(params: {
    orderId: string;
    userId: string;
    received: number;
    method?: string;
  }) {
    const paid = await this.prisma.$transaction(async (tx) => {
      const order = await tx.order.findUnique({ where: { id: params.orderId } });
      if (!order) throw new BadRequestException('Commande introuvable');
      if (order.paymentStatus === 'PAYE') {
        return tx.order.findUniqueOrThrow({
          where: { id: order.id },
          include: { items: true, payments: true, invoice: true },
        });
      }
      if (order.type === 'LIVRAISON' && order.status !== 'LIVREE') {
        throw new BadRequestException('Encaissement COD après confirmation OTP (commande LIVREE).');
      }
      const method = params.method ?? 'ESPECES';
      if (method === 'MOBILE_MONEY' || method === 'CARTE') {
        throw new BadRequestException(
          'Ce mode exige la confirmation opérateur (webhook FlexPay / Stripe), pas une saisie caisse.',
        );
      }
      const received = params.received;
      if (received < order.total) {
        throw new BadRequestException('Montant insuffisant');
      }
      const pending = await tx.payment.findFirst({
        where: { orderId: order.id, status: 'EN_ATTENTE', method: 'ESPECES' },
        orderBy: { createdAt: 'desc' },
      });
      if (pending) {
        await tx.payment.update({
          where: { id: pending.id },
          data: {
            status: 'CONFIRME',
            received,
            changeDue: received - order.total,
            confirmedAt: new Date(),
            userId: params.userId,
          },
        });
      } else {
        await tx.payment.create({
          data: {
            orderId: order.id,
            method,
            status: 'CONFIRME',
            amount: order.total,
            received,
            changeDue: received - order.total,
            provider: 'CASH',
            confirmedAt: new Date(),
            userId: params.userId,
          },
        });
      }
      await tx.order.update({
        where: { id: order.id },
        data: {
          paid: order.total,
          changeDue: received - order.total,
          paymentStatus: 'PAYE',
        },
      });
      return tx.order.findUniqueOrThrow({
        where: { id: order.id },
        include: { items: true, payments: true, invoice: true },
      });
    });
    await this.afterPaid(paid.id);
    return this.reload(paid.id);
  }

  async confirmFlexPayCallback(body: Record<string, unknown>) {
    if (!this.flexpay.configured()) {
      throw new BadRequestException('FlexPay non configuré : callback ignoré');
    }
    const reference = String(body.reference ?? body.Reference ?? '');
    const orderNumber = String(body.orderNumber ?? body.order_number ?? '');
    if (!reference && !orderNumber) {
      throw new BadRequestException('Callback FlexPay sans référence');
    }
    const payment = await this.findByRefs(reference, orderNumber);
    const check = await this.flexpay.check(payment.operatorRef ?? orderNumber);
    await this.prisma.payment.update({
      where: { id: payment.id },
      data: { webhookPayload: JSON.stringify({ callback: body, check: check.raw }) },
    });
    if (check.paid) {
      return this.markPaid(payment.id, {
        operatorRef: check.orderNumber,
        providerNote: String(body.provider_reference ?? body.Provider_reference ?? check.orderNumber),
      });
    }
    if (check.failed) {
      await this.prisma.payment.update({
        where: { id: payment.id },
        data: { status: 'ECHEC' },
      });
    }
    return this.reload(payment.orderId);
  }

  async confirmStripeEvent(event: { type?: string; data?: { object?: Record<string, unknown> } }) {
    const object = event.data?.object ?? {};
    const operatorRef = String(object.id ?? '');
    const metadata = (object.metadata ?? {}) as { providerRef?: string };
    const payment = await this.findByRefs(metadata.providerRef ?? '', operatorRef);
    if (event.type === 'payment_intent.succeeded') {
      return this.markPaid(payment.id, { operatorRef });
    }
    if (event.type === 'payment_intent.payment_failed') {
      await this.prisma.payment.update({
        where: { id: payment.id },
        data: {
          status: 'ECHEC',
          webhookPayload: JSON.stringify(event),
        },
      });
    }
    return this.reload(payment.orderId);
  }

  async confirmVirement(params: {
    paymentId: string;
    bankReference: string;
    userId: string;
  }) {
    const payment = await this.prisma.payment.findUnique({
      where: { id: params.paymentId },
    });
    if (!payment) throw new BadRequestException('Paiement introuvable');
    if (payment.method !== 'VIREMENT') {
      throw new BadRequestException('Seul un virement peut être rapproché manuellement');
    }
    if (!params.bankReference.trim()) {
      throw new BadRequestException('Référence bancaire obligatoire');
    }
    return this.markPaid(payment.id, {
      operatorRef: params.bankReference.trim(),
      userId: params.userId,
    });
  }

  markPending(orderId: string) {
    return this.prisma.order.update({
      where: { id: orderId },
      data: { paymentStatus: 'EN_ATTENTE' },
    });
  }

  private async startMobileMoney(
    order: { id: string; number: string; total: number; customerPhone: string | null },
    params: { userId: string; phone?: string },
  ) {
    if (!this.flexpay.configured()) {
      throw new BadRequestException(
        'Mobile Money FlexPay non configuré (FLEXPAY_TOKEN / FLEXPAY_MERCHANT). Aucune simulation.',
      );
    }
    const phone = params.phone || order.customerPhone;
    if (!phone) throw new BadRequestException('Numéro Mobile Money requis');
    const providerRef = `NDJ-MM-${randomUUID()}`;
    const publicBase = process.env.PUBLIC_BASE_URL ?? 'http://localhost:3000';
    const charged = await this.flexpay.chargeMobile({
      reference: providerRef,
      phone,
      amount: order.total,
      callbackUrl: `${publicBase}/webhooks/flexpay`,
      description: `Commande ${order.number}`,
    });
    await this.prisma.payment.create({
      data: {
        orderId: order.id,
        method: 'MOBILE_MONEY',
        status: 'EN_ATTENTE',
        amount: order.total,
        received: 0,
        changeDue: 0,
        provider: 'FLEXPAY',
        providerRef,
        operatorRef: charged.orderNumber,
        userId: params.userId,
      },
    });
    await this.prisma.order.update({
      where: { id: order.id },
      data: { paymentStatus: 'EN_ATTENTE' },
    });
    return {
      ...(await this.reload(order.id)),
      checkout: {
        provider: 'FLEXPAY',
        providerRef,
        operatorRef: charged.orderNumber,
        phone: charged.phone,
        status: 'EN_ATTENTE',
        message:
          'Paiement envoyé au téléphone du client. Le statut passera à PAYE uniquement après confirmation FlexPay.',
      },
    };
  }

  private async startCard(
    order: { id: string; number: string; total: number },
    params: { userId: string },
  ) {
    const providerRef = `NDJ-CARD-${randomUUID()}`;
    const publicBase = process.env.PUBLIC_BASE_URL ?? 'http://localhost:3000';
    if (this.flexpay.configured()) {
      const charged = await this.flexpay.chargeCard({
        reference: providerRef,
        amount: order.total,
        callbackUrl: `${publicBase}/webhooks/flexpay`,
        approveUrl: `${publicBase}/invoices/verify/pending`,
        cancelUrl: `${publicBase}/invoices/verify/pending`,
        description: `Commande ${order.number}`,
      });
      await this.prisma.payment.create({
        data: {
          orderId: order.id,
          method: 'CARTE',
          status: 'EN_ATTENTE',
          amount: order.total,
          received: 0,
          changeDue: 0,
          provider: 'FLEXPAY',
          providerRef,
          operatorRef: charged.orderNumber,
          checkoutUrl: charged.checkoutUrl,
          userId: params.userId,
        },
      });
      await this.prisma.order.update({
        where: { id: order.id },
        data: { paymentStatus: 'EN_ATTENTE' },
      });
      return {
        ...(await this.reload(order.id)),
        checkout: {
          provider: 'FLEXPAY',
          providerRef,
          operatorRef: charged.orderNumber,
          checkoutUrl: charged.checkoutUrl,
          status: 'EN_ATTENTE',
          message: 'Ouvrez l’URL carte FlexPay. PAYE uniquement après webhook + check opérateur.',
        },
      };
    }
    if (this.stripe.configured()) {
      const intent = await this.stripe.createIntent({
        amount: order.total,
        reference: providerRef,
        orderNumber: order.number,
      });
      await this.prisma.payment.create({
        data: {
          orderId: order.id,
          method: 'CARTE',
          status: 'EN_ATTENTE',
          amount: order.total,
          received: 0,
          changeDue: 0,
          provider: 'STRIPE',
          providerRef,
          operatorRef: intent.operatorRef,
          userId: params.userId,
        },
      });
      await this.prisma.order.update({
        where: { id: order.id },
        data: { paymentStatus: 'EN_ATTENTE' },
      });
      return {
        ...(await this.reload(order.id)),
        checkout: {
          provider: 'STRIPE',
          providerRef,
          operatorRef: intent.operatorRef,
          clientSecret: intent.clientSecret,
          status: 'EN_ATTENTE',
          message: 'Paiement carte Stripe. PAYE uniquement après webhook payment_intent.succeeded.',
        },
      };
    }
    throw new BadRequestException(
      'Paiement carte non configuré (FLEXPAY_TOKEN ou STRIPE_SECRET_KEY). Aucune simulation.',
    );
  }

  private async startTransfer(
    order: { id: string; number: string; total: number },
    params: { userId: string },
  ) {
    const providerRef = `NDJ-VIR-${order.number}-${Date.now()}`;
    await this.prisma.payment.create({
      data: {
        orderId: order.id,
        method: 'VIREMENT',
        status: 'EN_ATTENTE',
        amount: order.total,
        received: 0,
        changeDue: 0,
        provider: 'BANQUE',
        providerRef,
        operatorRef: providerRef,
        userId: params.userId,
      },
    });
    await this.prisma.order.update({
      where: { id: order.id },
      data: { paymentStatus: 'EN_ATTENTE' },
    });
    return {
      ...(await this.reload(order.id)),
      checkout: {
        provider: 'BANQUE',
        providerRef,
        status: 'EN_ATTENTE',
        message:
          'Indiquez cette référence au virement. Le paiement restera EN_ATTENTE jusqu’au rapprochement de la référence bancaire.',
      },
    };
  }

  private async findByRefs(providerRef: string, operatorRef: string) {
    if (!providerRef && !operatorRef) {
      throw new BadRequestException('Référence opérateur manquante');
    }
    const payment = await this.prisma.payment.findFirst({
      where: {
        OR: [
          ...(providerRef ? [{ providerRef }] : []),
          ...(operatorRef ? [{ operatorRef }] : []),
        ],
      },
    });
    if (!payment) throw new BadRequestException('Paiement introuvable pour cette référence opérateur');
    return payment;
  }

  private async markPaid(
    paymentId: string,
    extra: { operatorRef?: string; providerNote?: string; userId?: string },
  ) {
    const payment = await this.prisma.payment.findUnique({ where: { id: paymentId } });
    if (!payment) throw new BadRequestException('Paiement introuvable');
    if (payment.status === 'CONFIRME') return this.reload(payment.orderId);
    await this.prisma.payment.update({
      where: { id: payment.id },
      data: {
        status: 'CONFIRME',
        received: payment.amount,
        confirmedAt: new Date(),
        operatorRef: extra.operatorRef ?? payment.operatorRef,
      },
    });
    await this.prisma.order.update({
      where: { id: payment.orderId },
      data: {
        paid: payment.amount,
        paymentStatus: 'PAYE',
      },
    });
    await this.afterPaid(payment.orderId);
    return this.reload(payment.orderId);
  }

  private async afterPaid(orderId: string) {
    const invoice = await this.invoices.issueForOrder(orderId);
    const order = await this.prisma.order.findUnique({ where: { id: orderId } });
    if (!order) return;
    await this.whatsapp.notify({
      orderId,
      event: 'FACTURE',
      title: 'Facture',
      message: `Paiement reçu pour ${order.number} — ${order.total} FC. Facture ${invoice?.number ?? order.number}.`,
      phone: order.customerPhone,
      documentPath: invoice?.pdfPath,
      documentName: invoice ? `${invoice.number}.pdf` : undefined,
    });
  }

  private reload(orderId: string) {
    return this.prisma.order.findUniqueOrThrow({
      where: { id: orderId },
      include: { items: true, payments: true, invoice: true },
    });
  }
}
