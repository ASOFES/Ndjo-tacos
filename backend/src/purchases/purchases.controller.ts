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
import { PurchasesService } from './purchases.service';
import { PrismaService } from '../prisma.service';
import { SiteProvisionService } from '../organization/site-provision.service';

@Controller()
@UseGuards(JwtGuard, AccessGuard)
export class PurchasesController {
  constructor(
    private readonly purchases: PurchasesService,
    private readonly prisma: PrismaService,
    private readonly sites: SiteProvisionService,
  ) {}

  @Get('suppliers')
  @RequirePermission('achats.voir', 'stock.voir')
  async suppliers(@Query('establishmentId') establishmentId: string) {
    await this.sites.ensureReady(establishmentId);
    return this.purchases.listSuppliers(establishmentId);
  }

  @Post('suppliers')
  @RequirePermission('achats.modifier')
  createSupplier(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const establishmentId = req.scopedEstablishmentId ?? body.establishmentId;
    if (!establishmentId) throw new BadRequestException('Établissement requis');
    return this.purchases.createSupplier({ ...body, establishmentId }, req.user.sub);
  }

  @Put('suppliers/:id')
  @RequirePermission('achats.modifier')
  async updateSupplier(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const supplier = mustExist(await this.prisma.supplier.findUnique({ where: { id } }), 'Fournisseur introuvable');
    assertSameEstablishment(supplier.establishmentId, req);
    return this.purchases.updateSupplier(id, body, req.user.sub);
  }

  @Get('purchases')
  @RequirePermission('achats.voir', 'stock.voir')
  async list(@Query('establishmentId') establishmentId: string) {
    await this.sites.ensureReady(establishmentId);
    return this.purchases.listPurchases(establishmentId);
  }

  @Get('purchases/:id')
  @RequirePermission('achats.voir', 'stock.voir')
  async one(@Param('id') id: string, @Req() req: AuthedRequest) {
    const purchase = mustExist(await this.purchases.onePurchase(id), 'Achat introuvable');
    assertSameEstablishment(purchase.establishmentId, req);
    return purchase;
  }

  @Post('purchases')
  @RequirePermission('achats.modifier')
  create(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const establishmentId = req.scopedEstablishmentId ?? body.establishmentId;
    if (!establishmentId) throw new BadRequestException('Établissement requis');
    return this.purchases.createPurchase({ ...body, establishmentId }, req.user.sub);
  }

  @Post('purchases/:id/receive')
  @RequirePermission('achats.recevoir', 'stock.entree')
  async receive(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const purchase = mustExist(await this.prisma.purchase.findUnique({ where: { id } }), 'Achat introuvable');
    assertSameEstablishment(purchase.establishmentId, req);
    return this.purchases.receive(id, body, req.user.sub);
  }
}
