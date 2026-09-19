import { BadRequestException, Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { normalizeCustomerCategory } from '../orders/discount.rules';

const addressInclude = { zone: true };
const customerInclude = {
  addresses: { include: addressInclude, orderBy: [{ isDefault: 'desc' as const }, { createdAt: 'asc' as const }] },
};

export type DeliveryParty = {
  customerId?: string | null;
  addressId?: string | null;
  zoneId?: string | null;
  customerName?: string | null;
  customerPhone?: string | null;
  address?: string | null;
  zone?: string | null;
  deliveryFee: number;
};

@Injectable()
export class CustomersService {
  constructor(private readonly prisma: PrismaService) {}

  list(establishmentId: string) {
    return this.prisma.customer.findMany({
      where: { establishmentId },
      include: customerInclude,
      orderBy: { name: 'asc' },
    });
  }

  one(id: string) {
    return this.prisma.customer.findUnique({
      where: { id },
      include: customerInclude,
    });
  }

  async create(body: {
    establishmentId: string;
    name: string;
    phone: string;
    email?: string;
    notes?: string;
    status?: string;
    category?: string;
  }, userId: string) {
    const name = String(body.name ?? '').trim();
    const phone = String(body.phone ?? '').trim();
    if (!name || !phone) throw new BadRequestException('Nom et téléphone sont obligatoires');
    const category = normalizeCustomerCategory(body.category);
    try {
      const customer = await this.prisma.customer.create({
        data: {
          name,
          phone,
          email: body.email?.trim() || null,
          notes: body.notes?.trim() || null,
          status: body.status ?? 'ACTIF',
          category,
          establishmentId: body.establishmentId,
        },
        include: customerInclude,
      });
      await this.audit(userId, 'CREER', 'CLIENT', customer.id, `${customer.name} · ${customer.phone}`, body.establishmentId);
      return customer;
    } catch {
      throw new BadRequestException('Un client avec ce téléphone existe déjà dans l’établissement');
    }
  }

  async update(id: string, body: {
    name?: string;
    phone?: string;
    email?: string | null;
    notes?: string | null;
    status?: string;
    category?: string;
  }, userId: string) {
    const before = await this.prisma.customer.findUnique({ where: { id } });
    if (!before) throw new BadRequestException('Client introuvable');
    const customer = await this.prisma.customer.update({
      where: { id },
      data: {
        name: body.name?.trim() || before.name,
        phone: body.phone?.trim() || before.phone,
        email: body.email === undefined ? before.email : body.email?.trim() || null,
        notes: body.notes === undefined ? before.notes : body.notes?.trim() || null,
        status: body.status ?? before.status,
        category:
          body.category === undefined
            ? before.category
            : normalizeCustomerCategory(body.category),
      },
      include: customerInclude,
    });
    await this.audit(userId, 'MODIFIER', 'CLIENT', id, customer.name, before.establishmentId);
    return customer;
  }

  async addAddress(customerId: string, body: {
    label?: string;
    address: string;
    zoneId?: string;
    latitude?: string;
    longitude?: string;
    isDefault?: boolean;
  }, userId: string) {
    const customer = await this.prisma.customer.findUnique({ where: { id: customerId } });
    if (!customer) throw new BadRequestException('Client introuvable');
    const address = String(body.address ?? '').trim();
    if (!address) throw new BadRequestException('Adresse obligatoire');
    if (body.zoneId) await this.assertZone(body.zoneId, customer.establishmentId);
    if (body.isDefault) {
      await this.prisma.customerAddress.updateMany({
        where: { customerId },
        data: { isDefault: false },
      });
    }
    const created = await this.prisma.customerAddress.create({
      data: {
        customerId,
        address,
        label: String(body.label ?? 'Maison').trim() || 'Maison',
        zoneId: body.zoneId || null,
        latitude: body.latitude?.trim() || null,
        longitude: body.longitude?.trim() || null,
        isDefault: body.isDefault ?? false,
      },
      include: addressInclude,
    });
    await this.audit(userId, 'CREER', 'ADRESSE', created.id, `${customer.name} · ${created.label}`, customer.establishmentId);
    return created;
  }

  async updateAddress(id: string, body: {
    label?: string;
    address?: string;
    zoneId?: string | null;
    latitude?: string | null;
    longitude?: string | null;
    isDefault?: boolean;
  }, userId: string) {
    const before = await this.prisma.customerAddress.findUnique({
      where: { id },
      include: { customer: true },
    });
    if (!before) throw new BadRequestException('Adresse introuvable');
    if (body.zoneId) await this.assertZone(body.zoneId, before.customer.establishmentId);
    if (body.isDefault) {
      await this.prisma.customerAddress.updateMany({
        where: { customerId: before.customerId },
        data: { isDefault: false },
      });
    }
    return this.prisma.customerAddress.update({
      where: { id },
      data: {
        label: body.label?.trim() || before.label,
        address: body.address?.trim() || before.address,
        zoneId: body.zoneId === undefined ? before.zoneId : body.zoneId || null,
        latitude: body.latitude === undefined ? before.latitude : body.latitude,
        longitude: body.longitude === undefined ? before.longitude : body.longitude,
        isDefault: body.isDefault ?? before.isDefault,
      },
      include: addressInclude,
    });
  }

  listZones(establishmentId: string, activeOnly = false) {
    return this.prisma.deliveryZone.findMany({
      where: {
        establishmentId,
        ...(activeOnly ? { status: 'ACTIF' } : {}),
      },
      orderBy: { fee: 'asc' },
    });
  }

  async createZone(body: {
    establishmentId: string;
    code: string;
    name: string;
    fee: number;
    status?: string;
  }, userId: string) {
    const code = String(body.code ?? '').trim().toUpperCase();
    const name = String(body.name ?? '').trim();
    const fee = Number(body.fee);
    if (!code || !name || !Number.isFinite(fee) || fee < 0) {
      throw new BadRequestException('Code, nom et frais sont obligatoires');
    }
    try {
      const zone = await this.prisma.deliveryZone.create({
        data: {
          code,
          name,
          fee: Math.round(fee),
          status: body.status ?? 'ACTIF',
          establishmentId: body.establishmentId,
        },
      });
      await this.audit(userId, 'CREER', 'ZONE', zone.id, `${zone.name} · ${zone.fee} FC`, body.establishmentId);
      return zone;
    } catch {
      throw new BadRequestException('Ce code de zone existe déjà dans l’établissement');
    }
  }

  async updateZone(id: string, body: {
    code?: string;
    name?: string;
    fee?: number;
    status?: string;
  }, userId: string) {
    const before = await this.prisma.deliveryZone.findUnique({ where: { id } });
    if (!before) throw new BadRequestException('Zone introuvable');
    const zone = await this.prisma.deliveryZone.update({
      where: { id },
      data: {
        code: body.code?.trim().toUpperCase() || before.code,
        name: body.name?.trim() || before.name,
        fee: body.fee == null ? before.fee : Math.round(Number(body.fee)),
        status: body.status ?? before.status,
      },
    });
    await this.audit(userId, 'MODIFIER', 'ZONE', id, `${zone.name} · ${zone.fee} FC`, before.establishmentId);
    return zone;
  }

  async quote(params: {
    establishmentId: string;
    zoneId?: string;
    addressId?: string;
  }) {
    const party = await this.resolveDelivery({
      establishmentId: params.establishmentId,
      type: 'LIVRAISON',
      zoneId: params.zoneId,
      addressId: params.addressId,
    });
    return {
      zoneId: party.zoneId,
      zone: party.zone,
      deliveryFee: party.deliveryFee,
      address: party.address,
    };
  }

  async resolveDelivery(body: {
    establishmentId: string;
    type?: string;
    customerId?: string;
    addressId?: string;
    zoneId?: string;
    customerName?: string;
    customerPhone?: string;
    address?: string;
    zone?: string;
    deliveryFee?: number;
  }): Promise<DeliveryParty> {
    const type = body.type ?? 'SUR_PLACE';
    let customer = body.customerId
      ? await this.prisma.customer.findUnique({
          where: { id: body.customerId },
          include: customerInclude,
        })
      : null;
    if (customer && customer.establishmentId !== body.establishmentId) {
      throw new BadRequestException('Client hors établissement');
    }
    if (!customer && body.customerPhone?.trim()) {
      customer = await this.prisma.customer.findUnique({
        where: {
          establishmentId_phone: {
            establishmentId: body.establishmentId,
            phone: body.customerPhone.trim(),
          },
        },
        include: customerInclude,
      });
    }

    let address = body.addressId
      ? await this.prisma.customerAddress.findUnique({
          where: { id: body.addressId },
          include: addressInclude,
        })
      : null;
    if (address && customer && address.customerId !== customer.id) {
      throw new BadRequestException('Adresse hors fiche client');
    }
    if (address && !customer) {
      customer = await this.prisma.customer.findUnique({
        where: { id: address.customerId },
        include: customerInclude,
      });
    }

    let zone = body.zoneId
      ? await this.prisma.deliveryZone.findUnique({ where: { id: body.zoneId } })
      : address?.zone ?? null;
    if (!zone && body.zone?.trim()) {
      zone = await this.prisma.deliveryZone.findFirst({
        where: {
          establishmentId: body.establishmentId,
          status: 'ACTIF',
          OR: [
            { code: body.zone.trim().toUpperCase() },
            { name: { equals: body.zone.trim() } },
          ],
        },
      });
    }
    if (zone && zone.establishmentId !== body.establishmentId) {
      throw new BadRequestException('Zone hors établissement');
    }

    if (type !== 'LIVRAISON') {
      return {
        customerId: customer?.id ?? null,
        addressId: null,
        zoneId: null,
        customerName: customer?.name ?? body.customerName ?? null,
        customerPhone: customer?.phone ?? body.customerPhone ?? null,
        address: null,
        zone: null,
        deliveryFee: 0,
      };
    }

    if (!zone) {
      throw new BadRequestException('Zone de livraison obligatoire pour calculer les frais');
    }
    if (zone.status !== 'ACTIF') {
      throw new BadRequestException('Cette zone de livraison est inactive');
    }

    return {
      customerId: customer?.id ?? null,
      addressId: address?.id ?? null,
      zoneId: zone.id,
      customerName: customer?.name ?? body.customerName ?? null,
      customerPhone: customer?.phone ?? body.customerPhone ?? null,
      address: address?.address ?? body.address ?? null,
      zone: zone.name,
      deliveryFee: zone.fee,
    };
  }

  async ensureCustomer(body: {
    establishmentId: string;
    name?: string;
    phone?: string;
    email?: string;
  }) {
    const phone = body.phone?.trim();
    const name = body.name?.trim();
    if (!phone || !name) return null;
    const existing = await this.prisma.customer.findUnique({
      where: { establishmentId_phone: { establishmentId: body.establishmentId, phone } },
    });
    if (existing) {
      if (existing.name !== name || (body.email && existing.email !== body.email)) {
        return this.prisma.customer.update({
          where: { id: existing.id },
          data: { name, email: body.email?.trim() || existing.email },
        });
      }
      return existing;
    }
    return this.prisma.customer.create({
      data: {
        name,
        phone,
        email: body.email?.trim() || null,
        establishmentId: body.establishmentId,
      },
    });
  }

  private async assertZone(zoneId: string, establishmentId: string) {
    const zone = await this.prisma.deliveryZone.findUnique({ where: { id: zoneId } });
    if (!zone || zone.establishmentId !== establishmentId) {
      throw new BadRequestException('Zone hors établissement');
    }
    return zone;
  }

  private audit(userId: string, action: string, entity: string, entityId: string, details: string, establishmentId: string) {
    return this.prisma.auditLog.create({
      data: { userId, action, entity, entityId, details, establishmentId },
    });
  }
}
