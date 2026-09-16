import {
  Body,
  Controller,
  Get,
  Post,
  Put,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { createHash } from 'crypto';
import { PrismaService } from '../prisma.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { HealthService } from './health.service';

@Controller('admin/ops')
@UseGuards(JwtGuard, AccessGuard)
export class OpsController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly health: HealthService,
  ) {}

  @Get('health')
  @RequirePermission('systeme.voir', 'rapports.voir')
  healthSnapshot() {
    return this.health.snapshot();
  }

  @Put('flags')
  @RequirePermission('admin.ecrire')
  async saveFlag(
    @Body() body: { key: string; status: string; message?: string },
    @Req() req: { user: { sub: string } },
  ) {
    const flag = await this.prisma.systemFlag.upsert({
      where: { key: body.key },
      update: { status: body.status, message: body.message },
      create: { key: body.key, status: body.status, message: body.message },
    });
    await this.prisma.auditLog.create({
      data: {
        userId: req.user.sub,
        action: 'MAINTENANCE',
        entity: 'SYSTEME',
        details: `${body.key} → ${body.status}`,
        newValue: body.message,
      },
    });
    return flag;
  }

  @Get('sync')
  @RequirePermission('sync.voir', 'systeme.voir')
  async syncCenter(@Query('establishmentId') establishmentId?: string) {
    const establishments = await this.prisma.establishment.findMany({
      where: establishmentId ? { id: establishmentId } : undefined,
      orderBy: { name: 'asc' },
    });
    const devices = await this.prisma.deviceDeployment.findMany({
      where: establishmentId ? { establishmentId } : undefined,
      include: { establishment: true },
      orderBy: { lastSeenAt: 'desc' },
    });
    const now = Date.now();
    return {
      establishments: establishments.map((place) => {
        const owned = devices.filter((device) => device.establishmentId === place.id);
        const pending = owned.reduce((sum, device) => sum + device.pendingOps, 0);
        const stale = owned.some(
          (device) => now - device.lastSeenAt.getTime() > 2 * 60 * 60 * 1000,
        );
        return {
          id: place.id,
          code: place.code,
          name: place.name,
          status: pending > 0 ? 'ORANGE' : stale ? 'ROUGE' : 'VERT',
          pendingOps: pending,
          devices: owned.length,
        };
      }),
      devices: devices.map((device) => ({
        id: device.id,
        deviceName: device.deviceName,
        role: device.role,
        establishment: device.establishment.name,
        pendingOps: device.pendingOps,
        lastSyncAt: device.lastSyncAt,
        lastSeenAt: device.lastSeenAt,
        lastError: device.lastError,
        status:
          device.pendingOps > 0
            ? 'ORANGE'
            : now - device.lastSeenAt.getTime() > 2 * 60 * 60 * 1000
              ? 'ROUGE'
              : 'VERT',
      })),
    };
  }

  @Post('heartbeat')
  heartbeat(
    @Body()
    body: {
      establishmentId: string;
      deviceName: string;
      role: string;
      appBuild: number;
      catalogVersion?: string;
      pendingOps?: number;
      lastError?: string;
    },
  ) {
    const id = createHash('sha1')
      .update(`${body.establishmentId}:${body.deviceName}`)
      .digest('hex')
      .slice(0, 24);
    return this.prisma.deviceDeployment.upsert({
      where: { id },
      update: {
        appBuild: body.appBuild,
        catalogVersion: body.catalogVersion,
        pendingOps: body.pendingOps ?? 0,
        lastError: body.lastError,
        lastSyncAt: new Date(),
        lastSeenAt: new Date(),
        status: (body.pendingOps ?? 0) > 0 ? 'EN_ATTENTE' : 'A_JOUR',
      },
      create: {
        id,
        deviceName: body.deviceName,
        role: body.role,
        appBuild: body.appBuild,
        catalogVersion: body.catalogVersion,
        pendingOps: body.pendingOps ?? 0,
        lastError: body.lastError,
        lastSyncAt: new Date(),
        establishmentId: body.establishmentId,
        status: (body.pendingOps ?? 0) > 0 ? 'EN_ATTENTE' : 'A_JOUR',
      },
    });
  }
}
