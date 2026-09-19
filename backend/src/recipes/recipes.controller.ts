import { Body, Controller, Delete, Get, NotFoundException, Param, Post, Query, Req, UseGuards } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { CatalogService } from '../catalog/catalog.service';
import { assertRecipeItemsValid } from '../orders/recipe.expand';

@Controller('recipes')
@UseGuards(JwtGuard, AccessGuard)
export class RecipesController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly catalog: CatalogService,
  ) {}

  @Get()
  @RequirePermission('catalogue.voir', 'stock.voir')
  list(@Query('establishmentId') establishmentId: string) {
    return this.prisma.recipe.findMany({
      where: { establishmentId },
      include: {
        product: true,
        items: { include: { ingredient: true } },
      },
    });
  }

  @Post()
  @RequirePermission('catalogue.modifier')
  async create(
    @Body()
    body: {
      establishmentId: string;
      productId: string;
      items: { ingredientId: string; quantity: number; unit: string }[];
    },
    @Req() req: { user: { sub: string } },
  ) {
    const items = body.items ?? [];
    if (!items.length) {
      const cleared = await this.catalog.clearRecipe(body.productId);
      if (!cleared) throw new NotFoundException('Produit introuvable');
      await this.prisma.auditLog.create({
        data: {
          userId: req.user.sub,
          action: 'SUPPRIMER',
          entity: 'RECETTE',
          details: `Composition vidée ${cleared.name} · sync multi-sites`,
        },
      });
      return { deleted: true, productId: body.productId };
    }
    await assertRecipeItemsValid(this.prisma, {
      establishmentId: body.establishmentId,
      productId: body.productId,
      items,
    });
    const recipe = await this.prisma.recipe.upsert({
      where: { productId: body.productId },
      update: {
        items: {
          deleteMany: {},
          create: items,
        },
      },
      create: {
        productId: body.productId,
        establishmentId: body.establishmentId,
        items: { create: items },
      },
      include: {
        product: true,
        items: { include: { ingredient: true } },
      },
    });
    await this.prisma.auditLog.create({
      data: {
        userId: req.user.sub,
        action: 'ENREGISTRER',
        entity: 'RECETTE',
        details: `Fiche recette ${recipe.product.name} · sync multi-sites`,
      },
    });
    await this.catalog.propagateRecipe(body.productId);
    return recipe;
  }

  @Delete(':productId')
  @RequirePermission('catalogue.modifier')
  async remove(@Param('productId') productId: string, @Req() req: { user: { sub: string } }) {
    const cleared = await this.catalog.clearRecipe(productId);
    if (!cleared) throw new NotFoundException('Produit introuvable');
    await this.prisma.auditLog.create({
      data: {
        userId: req.user.sub,
        action: 'SUPPRIMER',
        entity: 'RECETTE',
        details: `Composition supprimée ${cleared.name} · sync multi-sites`,
      },
    });
    return { deleted: true, productId, code: cleared.code };
  }
}
