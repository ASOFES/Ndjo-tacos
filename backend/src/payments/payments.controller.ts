import {
  BadRequestException,
  Body,
  Controller,
  ForbiddenException,
  Get,
  Headers,
  HttpCode,
  Param,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { RawBodyRequest } from '@nestjs/common';
import type { Request } from 'express';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { PaymentService } from './payment.service';
import { StripeAdapter } from './stripe.adapter';
import { assertSameEstablishment, AuthedRequest, mustExist } from '../auth/scope';
import { SkipThrottle } from '@nestjs/throttler';
import { PrismaService } from '../prisma.service';

@Controller()
export class PaymentsController {
  constructor(
    private readonly payments: PaymentService,
    private readonly stripe: StripeAdapter,
    private readonly prisma: PrismaService,
  ) {}

  @Post('payments/initiate')
  @UseGuards(JwtGuard, AccessGuard)
  @RequirePermission('ventes.creer', 'livraison.maj')
  async initiate(
    @Body() body: { orderId: string; method: string; received?: number; phone?: string },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const order = mustExist(
      await this.prisma.order.findUnique({ where: { id: body.orderId } }),
      'Commande introuvable',
    );
    assertSameEstablishment(order.establishmentId, req);
    return this.payments.initiate({
      orderId: order.id,
      userId: req.user.sub,
      method: body.method,
      received: body.received,
      phone: body.phone,
    });
  }

  @Get('payments/order/:orderId')
  @UseGuards(JwtGuard, AccessGuard)
  @RequirePermission('ventes.voir', 'livraison.voir')
  async status(
    @Param('orderId') orderId: string,
    @Req() req: AuthedRequest,
  ) {
    const order = mustExist(
      await this.prisma.order.findUnique({
        where: { id: orderId },
        include: { payments: true, invoice: true },
      }),
      'Commande introuvable',
    );
    assertSameEstablishment(order.establishmentId, req);
    return order;
  }

  @Post('payments/:id/confirm-virement')
  @UseGuards(JwtGuard, AccessGuard)
  @RequirePermission('ventes.creer')
  async confirmVirement(
    @Param('id') id: string,
    @Body() body: { bankReference?: string },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const payment = mustExist(
      await this.prisma.payment.findUnique({ include: { order: true }, where: { id } }),
      'Paiement introuvable',
    );
    assertSameEstablishment(payment.order.establishmentId, req);
    return this.payments.confirmVirement({
      paymentId: id,
      bankReference: body.bankReference ?? '',
      userId: req.user.sub,
    });
  }

  @Post('payments/:id/collect')
  @UseGuards(JwtGuard, AccessGuard)
  @RequirePermission('ventes.creer', 'livraison.maj')
  async collect(
    @Param('id') id: string,
    @Body() body: { received?: number },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const order = mustExist(
      await this.prisma.order.findUnique({ where: { id } }),
      'Commande introuvable',
    );
    assertSameEstablishment(order.establishmentId, req);
    return this.payments.collectCash({
      orderId: id,
      userId: req.user.sub,
      received: Number(body.received ?? 0),
      method: 'ESPECES',
    });
  }

  @Post('webhooks/flexpay')
  @SkipThrottle()
  @HttpCode(200)
  flexpay(@Body() body: Record<string, unknown>) {
    return this.payments.confirmFlexPayCallback(body);
  }

  @Post('webhooks/stripe')
  @SkipThrottle()
  @HttpCode(200)
  stripeWebhook(
    @Req() req: RawBodyRequest<Request>,
    @Headers('stripe-signature') signature?: string,
  ) {
    if (!req.rawBody || !this.stripe.verifySignature(req.rawBody, signature)) {
      throw new ForbiddenException('Signature Stripe invalide');
    }
    return this.payments.confirmStripeEvent(req.body);
  }

  @Post('public/orders/:token/pay')
  async publicPay(
    @Param('token') token: string,
    @Body() body: { method: string; phone?: string },
  ) {
    const order = mustExist(
      await this.prisma.order.findUnique({ where: { trackingToken: token } }),
      'Commande introuvable',
    );
    if (!['MOBILE_MONEY', 'CARTE', 'VIREMENT'].includes(body.method)) {
      throw new BadRequestException('Mode public limité aux opérateurs');
    }
    return this.payments.initiate({
      orderId: order.id,
      userId: order.userId,
      method: body.method,
      phone: body.phone ?? order.customerPhone ?? undefined,
    });
  }
}
