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
import { PrismaService } from '../prisma.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { StockService } from './stock.service';
import { InventoryService } from './inventory.service';
import { assertSameEstablishment, AuthedRequest, mustExist } from '../auth/scope';

@Controller('stock')
@UseGuards(JwtGuard, AccessGuard)
export class StockController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly stock: StockService,
    private readonly inventory: InventoryService,
  ) {}

  @Get('summary')
  @RequirePermission('stock.voir')
  async summary(@Query('establishmentId') establishmentId: string) {
    const products = await this.prisma.product.findMany({
      where: { establishmentId },
      include: { category: true, lots: true },
      orderBy: { name: 'asc' },
    });
    return products.map((product) => {
      const qty = product.lots.reduce((sum, lot) => sum + lot.qtyCurrent, 0);
      const expiring = product.lots.filter((lot) => {
        if (!lot.expiryDate || lot.qtyCurrent <= 0) return false;
        const days = (lot.expiryDate.getTime() - Date.now()) / 86400000;
        return days <= 7;
      }).length;
      return {
        ...product,
        stockQty: qty,
        stockValue: Math.round(product.lots.reduce((sum, lot) => sum + lot.qtyCurrent * lot.priceBuy, 0)),
        lotCount: product.lots.filter((lot) => lot.qtyCurrent > 0).length,
        buyPrices: [...new Set(product.lots.filter((lot) => lot.qtyCurrent > 0).map((lot) => lot.priceBuy))],
        lowStock: qty <= product.stockAlert && product.lots.length > 0,
        expiringLots: expiring,
      };
    });
  }

  @Get('lots')
  @RequirePermission('stock.voir')
  lots(
    @Query('establishmentId') establishmentId: string,
    @Query('productId') productId?: string,
  ) {
    return this.prisma.lot.findMany({
      where: {
        establishmentId,
        ...(productId ? { productId } : {}),
      },
      include: { product: true },
      orderBy: [{ expiryDate: 'asc' }, { createdAt: 'desc' }],
    });
  }

  @Get('movements')
  @RequirePermission('stock.voir')
  movements(@Query('establishmentId') establishmentId: string) {
    return this.prisma.stockMovement.findMany({
      where: { establishmentId },
      include: {
        product: true,
        lot: true,
        user: { select: { name: true } },
      },
      orderBy: { createdAt: 'desc' },
      take: 80,
    });
  }

  @Post('entries')
  @RequirePermission('stock.entree')
  async entry(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const product = await this.prisma.product.findUnique({
      where: { id: body.productId },
    });
    if (!product) throw new BadRequestException('Produit introuvable');
    const establishmentId = req.scopedEstablishmentId ?? body.establishmentId;
    assertSameEstablishment(product.establishmentId, req);
    return this.stock.receiveLot({
      productId: product.id,
      establishmentId,
      quantity: Number(body.quantity),
      priceBuy: Number(body.priceBuy ?? product.priceBuy),
      priceSell: Number(body.priceSell ?? product.priceSell),
      expiryDate: body.expiryDate,
      location: body.location,
      motif: body.motif ?? 'Réception directe',
      userId: req.user.sub,
    });
  }

  @Post('exits')
  @RequirePermission('stock.sortie')
  async exit(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const destination = String(body.destination ?? 'Cuisine');
    const toKitchen = destination === 'Cuisine';
    const used = await this.stock.consumeFefo({
      productId: body.productId,
      establishmentId: req.scopedEstablishmentId ?? body.establishmentId,
      quantity: Number(body.quantity),
      userId: req.user.sub,
      type: body.type ?? 'SORTIE',
      motif: toKitchen ? `CUI:${body.productId}` : (body.motif ?? 'Sortie stock'),
      destination,
    });
    return { applied: Number(body.quantity), lots: used, method: 'FEFO', destination };
  }

  @Get('transfers')
  @RequirePermission('stock.voir')
  transfers(@Query('establishmentId') establishmentId: string) {
    return this.prisma.transfer.findMany({
      where: { OR: [{ sourceId: establishmentId }, { destId: establishmentId }] },
      include: { source: true, dest: true, product: true },
      orderBy: { createdAt: 'desc' },
    });
  }

  @Post('transfers')
  @RequirePermission('stock.transfert')
  async transfer(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    assertSameEstablishment(body.sourceId, req);
    if (!body.destId || body.destId === body.sourceId) {
      throw new BadRequestException('Établissement destination invalide');
    }
    if (!body.productId || Number(body.quantity) <= 0) {
      throw new BadRequestException('Produit et quantité requis');
    }
    const number = await this.stock.nextNumber(this.prisma, 'TRF');
    return this.prisma.transfer.create({
      data: {
        number,
        sourceId: body.sourceId,
        destId: body.destId,
        productId: body.productId,
        lotId: body.lotId,
        quantity: Number(body.quantity),
        status: 'CREE',
      },
      include: { source: true, dest: true, product: true },
    });
  }

  @Post('transfers/:id/ship')
  @RequirePermission('stock.transfert')
  async shipTransfer(
    @Param('id') id: string,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const transfer = mustExist(
      await this.prisma.transfer.findUnique({ where: { id }, include: { product: true } }),
      'Transfert introuvable',
    );
    assertSameEstablishment(transfer.sourceId, req);
    if (transfer.status === 'RECU') throw new BadRequestException('Transfert déjà reçu');
    if (transfer.status === 'EN_TRANSIT') {
      throw new BadRequestException('Transfert déjà expédié');
    }
    const alreadyConsumed = await this.prisma.stockMovement.findFirst({
      where: {
        type: 'TRANSFERT',
        productId: transfer.productId,
        establishmentId: transfer.sourceId,
        destination: transfer.destId,
        motif: { contains: transfer.number },
      },
    });
    let lots: { number: string; quantity: number }[] = [];
    if (!alreadyConsumed) {
      lots = await this.stock.consumeFefo({
        productId: transfer.productId,
        establishmentId: transfer.sourceId,
        quantity: transfer.quantity,
        userId: req.user.sub,
        type: 'TRANSFERT',
        motif: `Expédition transfert ${transfer.number}`,
        destination: transfer.destId,
      });
    }
    const updated = await this.prisma.transfer.update({
      where: { id },
      data: { status: 'EN_TRANSIT', shippedAt: transfer.shippedAt ?? new Date() },
      include: { source: true, dest: true, product: true },
    });
    return { ...updated, sourceLots: lots };
  }

  @Post('transfers/:id/status')
  @RequirePermission('stock.transfert')
  transferStatus(@Param('id') id: string, @Body() body: { status: string }) {
    return this.prisma.transfer.update({
      where: { id },
      data: { status: body.status },
      include: { source: true, dest: true, product: true },
    });
  }

  @Post('transfers/:id/receive')
  @RequirePermission('stock.transfert', 'stock.entree')
  async receiveTransfer(
    @Param('id') id: string,
    @Body() body: { expiryDate?: string; location?: string },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const transfer = mustExist(
      await this.prisma.transfer.findUnique({ where: { id } }),
      'Transfert introuvable',
    );
    if (transfer.status === 'RECU') throw new BadRequestException('Transfert déjà reçu');
    if (transfer.status !== 'EN_TRANSIT') {
      throw new BadRequestException('Le transfert doit être expédié avant réception');
    }
    const sourceProduct = mustExist(
      await this.prisma.product.findUnique({ where: { id: transfer.productId } }),
      'Produit source introuvable',
    );
    let destProduct = await this.prisma.product.findUnique({
      where: {
        establishmentId_code: {
          establishmentId: transfer.destId,
          code: sourceProduct.code,
        },
      },
    });
    if (!destProduct) {
      destProduct = await this.prisma.product.create({
        data: {
          code: sourceProduct.code,
          name: sourceProduct.name,
          unit: sourceProduct.unit,
          priceBuy: sourceProduct.priceBuy,
          priceSell: sourceProduct.priceSell,
          kind: sourceProduct.kind,
          subcategory: sourceProduct.subcategory,
          format: sourceProduct.format,
          volume: sourceProduct.volume,
          supplier: sourceProduct.supplier,
          categoryId: (
            await this.ensureDestCategory(sourceProduct.categoryId, transfer.destId)
          ).id,
          establishmentId: transfer.destId,
        },
      });
    }
    const lot = await this.stock.receiveLot({
      productId: destProduct.id,
      establishmentId: transfer.destId,
      quantity: transfer.quantity,
      priceBuy: sourceProduct.priceBuy,
      expiryDate: body.expiryDate,
      location: body.location ?? 'Dépôt destination',
      motif: `Réception transfert ${transfer.number}`,
      userId: req.user.sub,
    });
    return this.prisma.transfer.update({
      where: { id },
      data: { status: 'RECU', lotId: lot.id, receivedAt: new Date() },
      include: { source: true, dest: true, product: true },
    });
  }

  private async ensureDestCategory(sourceCategoryId: string, destId: string) {
    const source = await this.prisma.category.findUnique({ where: { id: sourceCategoryId } });
    const name = source?.name ?? 'Transferts';
    const existing = await this.prisma.category.findFirst({
      where: { establishmentId: destId, name },
    });
    return (
      existing ??
      this.prisma.category.create({ data: { name, establishmentId: destId } })
    );
  }

  @Get('inventories')
  @RequirePermission('stock.inventaire', 'stock.voir')
  inventories(@Query('establishmentId') establishmentId: string) {
    return this.inventory.listInventories(establishmentId);
  }

  @Get('inventories/:id')
  @RequirePermission('stock.inventaire', 'stock.voir')
  async inventoryOne(@Param('id') id: string, @Req() req: AuthedRequest) {
    const session = mustExist(await this.inventory.oneInventory(id), 'Inventaire introuvable');
    assertSameEstablishment(session.establishmentId, req);
    return session;
  }

  @Post('inventories')
  @RequirePermission('stock.inventaire')
  startInventory(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const establishmentId = req.scopedEstablishmentId ?? body.establishmentId;
    if (!establishmentId) throw new BadRequestException('Établissement requis');
    return this.inventory.start({ ...body, establishmentId }, req.user.sub);
  }

  @Put('inventories/:id/lines/:lineId')
  @RequirePermission('stock.inventaire')
  async countLine(
    @Param('id') id: string,
    @Param('lineId') lineId: string,
    @Body() body: { realQty: number; note?: string },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const session = mustExist(await this.inventory.oneInventory(id), 'Inventaire introuvable');
    assertSameEstablishment(session.establishmentId, req);
    return this.inventory.countLine(lineId, body, req.user.sub);
  }

  @Post('inventories/:id/submit')
  @RequirePermission('stock.inventaire')
  async submitInventory(@Param('id') id: string, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const session = mustExist(await this.inventory.oneInventory(id), 'Inventaire introuvable');
    assertSameEstablishment(session.establishmentId, req);
    return this.inventory.submit(id, req.user.sub);
  }

  @Post('inventories/:id/validate')
  @RequirePermission('stock.inventaire.valider')
  async validateInventory(@Param('id') id: string, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const session = mustExist(await this.inventory.oneInventory(id), 'Inventaire introuvable');
    assertSameEstablishment(session.establishmentId, req);
    return this.inventory.validate(id, req.user.sub);
  }

  @Get('losses')
  @RequirePermission('stock.pertes', 'stock.voir')
  losses(@Query('establishmentId') establishmentId: string) {
    return this.inventory.listLosses(establishmentId);
  }

  @Post('losses')
  @RequirePermission('stock.pertes')
  declareLoss(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const establishmentId = req.scopedEstablishmentId ?? body.establishmentId;
    if (!establishmentId) throw new BadRequestException('Établissement requis');
    return this.inventory.declareLoss({ ...body, establishmentId }, req.user.sub);
  }

  @Post('losses/:id/validate')
  @RequirePermission('stock.pertes.valider')
  async validateLoss(@Param('id') id: string, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const loss = mustExist(
      await this.prisma.stockLoss.findUnique({ where: { id } }),
      'Perte introuvable',
    );
    assertSameEstablishment(loss.establishmentId, req);
    return this.inventory.validateLoss(id, req.user.sub);
  }

  private async move(data: {
    type: string;
    quantity: number;
    motif: string;
    destination: string;
    productId: string;
    lotId?: string;
    establishmentId: string;
    userId: string;
  }) {
    const prefix = data.type === 'ENTREE' ? 'ENT' : data.type === 'INVENTAIRE' ? 'INV' : 'SORT';
    const number = await this.stock.nextNumber(this.prisma, prefix);
    return this.prisma.stockMovement.create({
      data: {
        ...data,
        number,
      },
    });
  }
}
