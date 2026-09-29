import { BadRequestException, Body, Controller, Get, Post, Query } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import * as bcrypt from 'bcryptjs';
import { PrismaService } from '../prisma.service';
import { OrdersService } from '../orders/orders.service';
import { SiteProvisionService } from '../organization/site-provision.service';

@Controller('public')
@Throttle({ default: { ttl: 60000, limit: 120 } })
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
    if (!String(body.establishmentId ?? '').trim()) {
      throw new BadRequestException('Choisissez un établissement');
    }
    if (!body.items?.length) {
      throw new BadRequestException('Panier vide');
    }
    const type = body.type ?? 'A_EMPORTER';
    if (type === 'LIVRAISON') {
      if (!String(body.zoneId ?? body.zone ?? '').trim()) {
        throw new BadRequestException('Choisissez une zone de livraison');
      }
      if (!String(body.address ?? '').trim()) {
        throw new BadRequestException('Indiquez l’adresse de livraison');
      }
      if (!String(body.customerPhone ?? '').trim()) {
        throw new BadRequestException('Téléphone obligatoire pour la livraison');
      }
    }
    const guest = await this.ensureGuest(body.establishmentId);
    return this.orders.create(
      {
        establishmentId: body.establishmentId,
        type,
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

  private async ensureGuest(establishmentId: string) {
    const existing =
      (await this.prisma.user.findUnique({ where: { username: 'client' } })) ??
      (await this.prisma.user.findFirst({ where: { role: 'CLIENT', status: 'ACTIF' } }));
    if (existing) return existing;
    const place =
      (await this.prisma.establishment.findUnique({ where: { id: establishmentId } })) ??
      (await this.prisma.establishment.findFirst({ where: { status: 'ACTIF' } }));
    if (!place) {
      throw new BadRequestException('Aucun établissement disponible pour la commande client');
    }
    return this.prisma.user.create({
      data: {
        name: 'Client NDJO',
        username: 'client',
        passwordHash: await bcrypt.hash('client123', 10),
        role: 'CLIENT',
        status: 'ACTIF',
        establishmentId: place.id,
      },
    });
  }

  @Get('delivery-zones')
  zones(@Query('establishmentId') establishmentId: string) {
    return this.prisma.deliveryZone.findMany({
      where: { establishmentId, status: 'ACTIF' },
      orderBy: { fee: 'asc' },
    });
  }
}
