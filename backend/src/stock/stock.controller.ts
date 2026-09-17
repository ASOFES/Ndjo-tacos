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
    const sourceId = req.scopedEstablishmentId ?? body.sourceId ?? body.establishmentId;
    assertSameEstablishment(sourceId, req);
    if (!body.destId || body.destId === sourceId) {
      throw new BadRequestException('Établissement destination invalide');
    }
    const quantity = Number(body.quantity);
    if (!body.productId || !Number.isFinite(quantity) || quantity <= 0) {
      throw new BadRequestException('Produit et quantité requis');
    }
    const dest = await this.prisma.establishment.findUnique({ where: { id: body.destId } });
    if (!dest) throw new BadRequestException('Établissement destination introuvable');
    const product = mustExist(
      await this.prisma.product.findUnique({ where: { id: body.productId } }),
      'Produit introuvable',
    );
    if (product.establishmentId !== sourceId) {
      throw new BadRequestException('Produit hors établissement source');
    }
    const available = await this.stock.availableByProduct(sourceId, [product.id]);
    const stockQty = available.get(product.id) ?? 0;
    if (stockQty + 0.0001 < quantity) {
      throw new BadRequestException(
        `Stock insuffisant pour transférer ${product.name} (besoin ${quantity}, stock ${stockQty})`,
      );
    }
    const number = await this.stock.nextNumber(this.prisma, 'TRF');
    const created = await this.prisma.transfer.create({
      data: {
        number,
        sourceId,
        destId: body.destId,
        productId: product.id,
        lotId: body.lotId,
        quantity,
        status: 'CREE',
      },
      include: { source: true, dest: true, product: true },
    });
    await this.prisma.auditLog.create({
      data: {
        userId: req.user.sub,
        action: 'CREER',
        entity: 'TRANSFERT',
        entityId: created.id,
        details: `${created.number} · ${product.name} · ${quantity} · ${created.source.name} → ${created.dest.name}`,
        establishmentId: sourceId,
      },
    });
    return created;
  }

  @Post('transfers/:id/ship')
  @RequirePermission('stock.transfert')
  async shipTransfer(
    @Param('id') id: string,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const transfer = mustExist(
      await this.prisma.transfer.findUnique({
        where: { id },
        include: { product: true, source: true, dest: true },
      }),
      'Transfert introuvable',
    );
    assertSameEstablishment(transfer.sourceId, req);
    if (transfer.status === 'ANNULE') throw new BadRequestException('Transfert annulé');
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
    await this.prisma.auditLog.create({
      data: {
        userId: req.user.sub,
        action: 'EXPEDIER',
        entity: 'TRANSFERT',
        entityId: updated.id,
        details: `${updated.number} expédié · ${transfer.product.name} · ${transfer.quantity} · en attente de réception à ${transfer.dest.name}`,
        oldValue: 'CREE',
        newValue: 'EN_TRANSIT',
        establishmentId: transfer.sourceId,
      },
    });
    return { ...updated, sourceLots: lots };
  }

  @Post('transfers/:id/status')
  @RequirePermission('stock.transfert')
  async transferStatus(
    @Param('id') id: string,
    @Body() body: { status: string },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const transfer = mustExist(
      await this.prisma.transfer.findUnique({ where: { id } }),
      'Transfert introuvable',
    );
    if (body.status !== 'ANNULE') {
      throw new BadRequestException(
        'Le stock destination n’entre qu’après validation de réception',
      );
    }
    assertSameEstablishment(transfer.sourceId, req);
    if (transfer.status !== 'CREE') {
      throw new BadRequestException('Seul un transfert non expédié peut être annulé');
    }
    return this.prisma.transfer.update({
      where: { id },
      data: { status: 'ANNULE' },
      include: { source: true, dest: true, product: true },
    });
  }

  @Post('transfers/:id/receive')
  @RequirePermission('stock.transfert', 'stock.entree')
  async receiveTransfer(
    @Param('id') id: string,
    @Body() body: { expiryDate?: string; location?: string; establishmentId?: string },
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const transfer = mustExist(
      await this.prisma.transfer.findUnique({
        where: { id },
        include: { product: true, source: true, dest: true },
      }),
      'Transfert introuvable',
    );
    assertSameEstablishment(transfer.destId, req);
    if (transfer.status === 'RECU') throw new BadRequestException('Transfert déjà reçu');
    if (transfer.status === 'ANNULE') throw new BadRequestException('Transfert annulé');
    if (transfer.status !== 'EN_TRANSIT') {
      throw new BadRequestException('Le transfert doit être expédié avant validation de réception');
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
    const alreadyIn = await this.prisma.stockMovement.findFirst({
      where: {
        establishmentId: transfer.destId,
        productId: destProduct.id,
        type: 'ENTREE',
        motif: { contains: transfer.number },
      },
    });
    const shipped = await this.prisma.stockMovement.findMany({
      where: {
        establishmentId: transfer.sourceId,
        type: 'TRANSFERT',
        motif: { contains: transfer.number },
      },
      include: { lot: true },
      orderBy: { createdAt: 'asc' },
    });
    let lastLotId = transfer.lotId;
    if (!alreadyIn) {
      const chunks = shipped.length
        ? shipped.map((move) => ({
            quantity: move.quantity,
            priceBuy: move.lot?.priceBuy ?? sourceProduct.priceBuy,
            expiryDate: move.lot?.expiryDate ?? body.expiryDate ?? null,
          }))
        : [
            {
              quantity: transfer.quantity,
              priceBuy: sourceProduct.priceBuy,
              expiryDate: body.expiryDate ?? null,
            },
          ];
      for (const chunk of chunks) {
        const lot = await this.stock.receiveLot({
          productId: destProduct.id,
          establishmentId: transfer.destId,
          quantity: chunk.quantity,
          priceBuy: chunk.priceBuy,
          expiryDate: chunk.expiryDate,
          location: body.location ?? `Transfert ${transfer.source.name}`,
          motif: `Réception transfert ${transfer.number}`,
          userId: req.user.sub,
        });
        lastLotId = lot.id;
      }
    }
    const updated = await this.prisma.transfer.update({
      where: { id },
      data: { status: 'RECU', lotId: lastLotId, receivedAt: new Date() },
      include: { source: true, dest: true, product: true },
    });
    await this.prisma.auditLog.create({
      data: {
        userId: req.user.sub,
        action: 'RECEPTION',
        entity: 'TRANSFERT',
        entityId: updated.id,
        details: `${updated.number} réception validée · ${sourceProduct.name} · ${transfer.quantity} · ${transfer.source.name} → ${transfer.dest.name}`,
        oldValue: 'EN_TRANSIT',
        newValue: 'RECU',
        establishmentId: transfer.destId,
      },
    });
    return updated;
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
