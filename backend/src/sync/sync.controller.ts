import { Body, Controller, Get, Post, Query, Req, UseGuards } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { AuthedRequest } from '../auth/scope';
import { SyncPushService } from './sync.service';

@Controller('sync')
@UseGuards(JwtGuard, AccessGuard)
export class SyncController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly sync: SyncPushService,
  ) {}

  @Get('pull')
  @RequirePermission(
    'ventes.voir',
    'commandes.voir',
    'catalogue.voir',
    'stock.voir',
    'cuisine.voir',
    'livraison.voir',
  )
  async pull(
    @Query('establishmentId') establishmentId: string,
    @Query('since') since?: string,
  ) {
    const after = since ? new Date(since) : new Date(0);
    const [products, lots, orders, recipes] = await Promise.all([
      this.prisma.product.findMany({
        where: { establishmentId, updatedAt: { gte: after } },
        include: {
          category: true,
          lots: { where: { status: 'ACTIF' } },
        },
      }),
      this.prisma.lot.findMany({
        where: { establishmentId },
        include: { product: { select: { name: true, code: true } } },
        orderBy: [{ expiryDate: 'asc' }, { createdAt: 'asc' }],
      }),
      this.prisma.order.findMany({
        where: { establishmentId, updatedAt: { gte: after } },
        include: { items: true, user: { select: { name: true } } },
        orderBy: { createdAt: 'desc' },
        take: 80,
      }),
      this.prisma.recipe.findMany({
        where: { establishmentId },
        include: { items: true },
      }),
    ]);
    return {
      serverTime: new Date().toISOString(),
      products,
      lots,
      orders,
      recipes,
    };
  }

  @Post('push')
  @RequirePermission(
    'ventes.creer',
    'commandes.creer',
    'stock.sortie',
    'stock.entree',
    'cuisine.statut',
    'livraison.maj',
    'gps.envoyer',
  )
  push(
    @Body()
    body: {
      operations: {
        clientUuid: string;
        type: string;
        payload: Record<string, unknown>;
      }[];
    },
    @Req()
    req: AuthedRequest & {
      user: { sub: string; role: string; establishmentId?: string };
    },
  ) {
    return this.sync.applyAll(body.operations ?? [], req);
  }
}
