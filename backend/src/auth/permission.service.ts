import { BadRequestException, Injectable, OnModuleInit } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import {
  DEFAULT_ROLE_PERMISSIONS,
  PERMISSION_CATALOG,
  ROLES,
} from './permission.catalog';

@Injectable()
export class PermissionService implements OnModuleInit {
  private cache = new Map<string, string[]>();

  constructor(private readonly prisma: PrismaService) {}

  async onModuleInit() {
    await this.ensureCatalog();
  }

  async ensureCatalog() {
    for (const item of PERMISSION_CATALOG) {
      await this.prisma.permission.upsert({
        where: { key: item.key },
        update: { label: item.label },
        create: item,
      });
    }
    const existing = await this.prisma.rolePermission.findMany({
      distinct: ['role'],
      select: { role: true },
    });
    const seeded = new Set(existing.map((row) => row.role));
    const catalog = await this.prisma.permission.findMany();
    const idByKey = Object.fromEntries(catalog.map((row) => [row.key, row.id]));
    for (const [role, keys] of Object.entries(DEFAULT_ROLE_PERMISSIONS)) {
      if (seeded.has(role)) continue;
      for (const key of keys) {
        const permissionId = idByKey[key];
        if (!permissionId) continue;
        await this.prisma.rolePermission.create({
          data: { role, permissionId },
        });
      }
    }
    const transferId = idByKey['stock.transfert'];
    if (transferId) {
      for (const role of ['GESTIONNAIRE', 'MAGASINIER'] as const) {
        await this.prisma.rolePermission.upsert({
          where: { role_permissionId: { role, permissionId: transferId } },
          create: { role, permissionId: transferId },
          update: {},
        });
      }
    }
    const purchaseId = idByKey['achats.modifier'];
    if (purchaseId) {
      for (const role of ['GESTIONNAIRE', 'MAGASINIER'] as const) {
        await this.prisma.rolePermission.upsert({
          where: { role_permissionId: { role, permissionId: purchaseId } },
          create: { role, permissionId: purchaseId },
          update: {},
        });
      }
    }
    this.cache.clear();
  }

  async keysFor(role: string): Promise<string[]> {
    if (role === 'SUPER_ADMIN') return ['*'];
    const cached = this.cache.get(role);
    if (cached) return cached;
    const rows = await this.prisma.rolePermission.findMany({
      where: { role },
      include: { permission: true },
    });
    const keys =
      rows.length > 0
        ? rows.map((row) => row.permission.key)
        : DEFAULT_ROLE_PERMISSIONS[role] ?? [];
    this.cache.set(role, keys);
    return keys;
  }

  async matrix() {
    await this.ensureCatalog();
    const permissions = await this.prisma.permission.findMany({
      orderBy: { key: 'asc' },
      include: { roles: true },
    });
    const roles = ROLES.map((role) => ({
      role,
      locked: role === 'SUPER_ADMIN',
      keys:
        role === 'SUPER_ADMIN'
          ? ['*']
          : permissions
              .filter((item) => item.roles.some((row) => row.role === role))
              .map((item) => item.key),
    }));
    return {
      source: 'database',
      permissions: permissions.map((item) => ({
        key: item.key,
        label: item.label,
      })),
      roles,
    };
  }

  async setRoleKeys(role: string, keys: string[], userId: string) {
    if (!ROLES.includes(role as (typeof ROLES)[number])) {
      throw new BadRequestException('Rôle inconnu');
    }
    if (role === 'SUPER_ADMIN') {
      throw new BadRequestException(
        'Le super administrateur conserve l’accès complet',
      );
    }
    const unique = [...new Set(keys.filter(Boolean))];
    if (unique.includes('*')) {
      unique.length = 0;
      unique.push('*');
    }
    const catalog = await this.prisma.permission.findMany({
      where: { key: { in: unique } },
    });
    if (catalog.length !== unique.length) {
      throw new BadRequestException('Permission inconnue');
    }
    const before = await this.keysFor(role);
    await this.prisma.$transaction(async (tx) => {
      await tx.rolePermission.deleteMany({ where: { role } });
      if (catalog.length) {
        await tx.rolePermission.createMany({
          data: catalog.map((item) => ({ role, permissionId: item.id })),
        });
      }
    });
    this.cache.delete(role);
    await this.prisma.auditLog.create({
      data: {
        userId,
        action: 'MODIFIER',
        entity: 'PERMISSIONS',
        entityId: role,
        details: `Matrice ${role}`,
        oldValue: before.join(','),
        newValue: unique.join(','),
      },
    });
    return this.matrix();
  }
}
