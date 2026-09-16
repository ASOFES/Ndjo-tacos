import { Body, Controller, Get, Param, Post, Query, Req, UseGuards } from '@nestjs/common';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { PaymentService } from '../payments/payment.service';
import { DeliveryService } from './delivery.service';
import { assertSameEstablishment, AuthedRequest, mustExist } from '../auth/scope';
import { PrismaService } from '../prisma.service';

@Controller('delivery')
@UseGuards(JwtGuard, AccessGuard)
export class DeliveryController {
  constructor(
    private readonly delivery: DeliveryService,
    private readonly payments: PaymentService,
    private readonly prisma: PrismaService,
  ) {}

  @Get('drivers')
  @RequirePermission('livraison.voir')
  drivers(@Query('establishmentId') establishmentId: string) {
    return this.delivery.drivers(establishmentId);
  }

  @Get('drivers/:id')
  @RequirePermission('livraison.voir')
  driverHistory(@Param('id') id: string) {
    return this.delivery.driverHistory(id);
  }

  @Get('me')
  @RequirePermission('livraison.voir')
  me(@Req() req: { user: { sub: string } }) {
    return this.delivery.driverHistory(req.user.sub);
  }

  @Get()
  @RequirePermission('livraison.voir')
  list(@Query('establishmentId') establishmentId: string) {
    return this.delivery.list(establishmentId);
  }

  @Post('availability')
  @RequirePermission('livraison.maj')
  availability(
    @Body() body: { availability: string },
    @Req() req: { user: { sub: string } },
  ) {
    return this.delivery.setAvailability(req.user.sub, body.availability);
  }

  @Post('location')
  @RequirePermission('gps.envoyer', 'livraison.maj')
  location(
    @Body() body: { latitude: number; longitude: number; orderId?: string },
    @Req() req: { user: { sub: string } },
  ) {
    return this.delivery.recordLocation(body, req.user.sub);
  }

  @Post(':id/assign')
  @RequirePermission('livraison.maj')
  async assign(
    @Param('id') id: string,
    @Body() body: { driverId?: string },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    await this.assertOrder(id, req);
    return this.delivery.assign(id, body.driverId, req);
  }

  @Post(':id/start')
  @RequirePermission('livraison.maj')
  async start(@Param('id') id: string, @Req() req: AuthedRequest & { user: { sub: string } }) {
    await this.assertOrder(id, req);
    return this.delivery.start(id, req);
  }

  @Post(':id/arrive')
  @RequirePermission('livraison.maj')
  async arrive(@Param('id') id: string, @Req() req: AuthedRequest & { user: { sub: string } }) {
    await this.assertOrder(id, req);
    return this.delivery.arrive(id, req);
  }

  @Post(':id/send-otp')
  @RequirePermission('livraison.maj')
  async sendOtp(
    @Param('id') id: string,
    @Req() req: AuthedRequest & { user: { sub: string; role: string } },
  ) {
    await this.assertOrder(id, req);
    return this.delivery.sendOtp(id, req);
  }

  @Post(':id/deliver')
  @RequirePermission('livraison.maj')
  async deliver(
    @Param('id') id: string,
    @Body()
    body: {
      otp?: string;
      proofPhotoUrl?: string;
      proofSignature?: string;
      latitude?: number;
      longitude?: number;
    },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    await this.assertOrder(id, req);
    return this.delivery.deliver(id, body, req);
  }

  @Post(':id/collect')
  @RequirePermission('livraison.maj', 'ventes.creer')
  async collect(
    @Param('id') id: string,
    @Body() body: { received?: number },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const current = await this.assertOrder(id, req);
    return this.payments.collectCash({
      orderId: id,
      userId: req.user.sub,
      received: Number(body.received ?? current.total),
      method: 'ESPECES',
    });
  }

  private async assertOrder(id: string, req: AuthedRequest) {
    const current = mustExist(
      await this.prisma.order.findUnique({ where: { id } }),
      'Commande introuvable',
    );
    assertSameEstablishment(current.establishmentId, req);
    return current;
  }
}
