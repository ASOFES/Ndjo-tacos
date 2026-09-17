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
import { assertSameEstablishment, AuthedRequest, mustExist } from '../auth/scope';
import { CatalogService, toProductDraft } from './catalog.service';
import { SiteProvisionService } from '../organization/site-provision.service';

@Controller('catalog')
@UseGuards(JwtGuard, AccessGuard)
export class CatalogController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly catalog: CatalogService,
    private readonly sites: SiteProvisionService,
  ) {}

  @Get('categories')
  @RequirePermission('catalogue.voir')
  async categories(@Query('establishmentId') establishmentId: string) {
    await this.sites.ensureReady(establishmentId);
    return this.prisma.category.findMany({
      where: { establishmentId },
      orderBy: { name: 'asc' },
    });
  }

  @Post('categories')
  @RequirePermission('catalogue.modifier')
  async createCategory(
    @Body() body: { name: string; establishmentId?: string },
    @Req() req: AuthedRequest,
  ) {
    const establishmentId = req.scopedEstablishmentId ?? body.establishmentId;
    if (!establishmentId || !body.name?.trim()) {
      throw new BadRequestException('Catégorie et établissement requis');
    }
    return this.prisma.category.create({
      data: { name: body.name.trim(), establishmentId },
    });
  }

  @Get('products')
  @RequirePermission('catalogue.voir', 'ventes.voir')
  async products(
    @Query('establishmentId') establishmentId: string,
    @Query('kind') kind?: string,
  ) {
    await this.sites.ensureReady(establishmentId);
    return this.catalog.list(establishmentId, kind);
  }

  @Get('products/:id')
  @RequirePermission('catalogue.voir', 'ventes.voir')
  async one(@Param('id') id: string, @Req() req: AuthedRequest) {
    const product = mustExist(
      await this.prisma.product.findUnique({
        where: { id },
        include: {
          category: true,
          lots: { orderBy: [{ expiryDate: 'asc' }, { createdAt: 'asc' }] },
          recipe: { include: { items: { include: { ingredient: true } } } },
        },
      }),
      'Produit introuvable',
    );
    assertSameEstablishment(product.establishmentId, req);
    return this.catalog.present(product);
  }

  @Post('products')
  @RequirePermission('catalogue.modifier')
  create(@Body() body: any, @Req() req: AuthedRequest & { user: { sub: string } }) {
    const establishmentId = req.scopedEstablishmentId ?? body.establishmentId;
    if (!establishmentId) throw new BadRequestException('Établissement requis');
    return this.catalog.create(toProductDraft(body, establishmentId), req.user.sub);
  }

  @Put('products/:id')
  @RequirePermission('catalogue.modifier')
  async update(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: AuthedRequest & { user: { sub: string } },
  ) {
    const before = mustExist(
      await this.prisma.product.findUnique({ where: { id } }),
      'Produit introuvable',
    );
    assertSameEstablishment(before.establishmentId, req);
    const establishmentId = before.establishmentId;
    return this.catalog.update(
      id,
      toProductDraft(body, establishmentId),
      req.user.sub,
    );
  }
}
