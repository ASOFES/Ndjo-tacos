import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Param,
  Post,
  Put,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { assertSameEstablishment, AuthedRequest, mustExist } from '../auth/scope';
import { CustomersService } from './customers.service';
import { PrismaService } from '../prisma.service';

@Controller()
@UseGuards(JwtGuard, AccessGuard)
export class CustomersController {
  constructor(
    private readonly customers: CustomersService,
    private readonly prisma: PrismaService,
  ) {}

  @Get('customers')
  @RequirePermission('clients.voir', 'ventes.voir')
  list(@Query('establishmentId') establishmentId: string) {
    return this.customers.list(establishmentId);
  }

  @Get('customers/:id')
  @RequirePermission('clients.voir', 'ventes.voir')
  async one(@Param('id') id: string, @Req() req: AuthedRequest) {
    const customer = mustExist(await this.customers.one(id), 'Client introuvable');
    assertSameEstablishment(customer.establishmentId, req);
    return customer;
  }

  @Post('customers')
  @RequirePermission('clients.modifier')
  create(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const establishmentId = req.scopedEstablishmentId ?? body.establishmentId;
    if (!establishmentId) throw new BadRequestException('Établissement requis');
    return this.customers.create({ ...body, establishmentId }, req.user.sub);
  }

  @Put('customers/:id')
  @RequirePermission('clients.modifier')
  async update(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const before = mustExist(await this.prisma.customer.findUnique({ where: { id } }), 'Client introuvable');
    assertSameEstablishment(before.establishmentId, req);
    return this.customers.update(id, body, req.user.sub);
  }

  @Post('customers/:id/addresses')
  @RequirePermission('clients.modifier')
  async addAddress(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const customer = mustExist(await this.prisma.customer.findUnique({ where: { id } }), 'Client introuvable');
    assertSameEstablishment(customer.establishmentId, req);
    return this.customers.addAddress(id, body, req.user.sub);
  }

  @Put('addresses/:id')
  @RequirePermission('clients.modifier')
  async updateAddress(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const address = mustExist(
      await this.prisma.customerAddress.findUnique({
        where: { id },
        include: { customer: true },
      }),
      'Adresse introuvable',
    );
    assertSameEstablishment(address.customer.establishmentId, req);
    return this.customers.updateAddress(id, body, req.user.sub);
  }

  @Get('delivery-zones')
  @RequirePermission('zones.voir', 'clients.voir', 'ventes.voir')
  zones(@Query('establishmentId') establishmentId: string) {
    return this.customers.listZones(establishmentId);
  }

  @Get('delivery-zones/quote')
  @RequirePermission('zones.voir', 'clients.voir', 'ventes.voir')
  quote(
    @Query('establishmentId') establishmentId: string,
    @Query('zoneId') zoneId?: string,
    @Query('addressId') addressId?: string,
  ) {
    return this.customers.quote({ establishmentId, zoneId, addressId });
  }

  @Post('delivery-zones')
  @RequirePermission('zones.modifier')
  createZone(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const establishmentId = req.scopedEstablishmentId ?? body.establishmentId;
    if (!establishmentId) throw new BadRequestException('Établissement requis');
    return this.customers.createZone({ ...body, establishmentId }, req.user.sub);
  }

  @Put('delivery-zones/:id')
  @RequirePermission('zones.modifier')
  async updateZone(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const zone = mustExist(await this.prisma.deliveryZone.findUnique({ where: { id } }), 'Zone introuvable');
    assertSameEstablishment(zone.establishmentId, req);
    return this.customers.updateZone(id, body, req.user.sub);
  }
}
