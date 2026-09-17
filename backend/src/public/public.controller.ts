import { Body, Controller, Get, Post, Query } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { PrismaService } from '../prisma.service';
import { OrdersService } from '../orders/orders.service';
import { SiteProvisionService } from '../organization/site-provision.service';

@Controller('public')
@Throttle({ default: { ttl: 60000, limit: 40 } })
export class PublicController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly orders: OrdersService,
    private readonly sites: SiteProvisionService,
  ) {}

  @Get('establishments')
  establishments() {
    return this.prisma.establishment.findMany({
      where: { status: 'ACTIF' },
      orderBy: { name: 'asc' },
    });
  }

  @Get('catalog')
  async catalog(@Query('establishmentId') establishmentId: string) {
    await this.sites.ensureReady(establishmentId);
    const categories = await this.prisma.category.findMany({
      where: { establishmentId },
      include: {
        products: {
          where: { status: 'ACTIF', kind: 'VENTE' },
          include: {
            recipe: {
              include: {
                items: { include: { ingredient: { select: { name: true } } } },
              },
            },
          },
          orderBy: { name: 'asc' },
        },
      },
      orderBy: { name: 'asc' },
    });
    return categories.filter((category) => category.products.length > 0);
  }

  @Post('orders')
  async order(
    @Body()
    body: {
      establishmentId: string;
      type?: string;
      customerName?: string;
      customerPhone?: string;
      address?: string;
      zone?: string;
      zoneId?: string;
      addressId?: string;
      customerId?: string;
      items: { productId: string; quantity: number }[];
      method?: string;
    },
  ) {
    const guest =
      (await this.prisma.user.findUnique({ where: { username: 'client' } })) ??
      (await this.prisma.user.findFirst({ where: { role: 'CLIENT' } }));
    if (!guest) {
      return { error: 'Compte client introuvable' };
    }
    return this.orders.create(
      {
        establishmentId: body.establishmentId,
        type: body.type ?? 'A_EMPORTER',
        customerName: body.customerName,
        customerPhone: body.customerPhone,
        address: body.address,
        zone: body.zone,
        zoneId: body.zoneId,
        addressId: body.addressId,
        customerId: body.customerId,
        items: body.items,
        method: body.method,
      },
      guest.id,
    );
  }

  @Get('delivery-zones')
  zones(@Query('establishmentId') establishmentId: string) {
    return this.prisma.deliveryZone.findMany({
      where: { establishmentId, status: 'ACTIF' },
      orderBy: { fee: 'asc' },
    });
  }
}
