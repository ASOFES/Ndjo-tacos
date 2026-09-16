import {
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
import { createHash } from 'crypto';
import { PrismaService } from '../prisma.service';
import { UpdatesService } from '../updates/updates.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { AuthedRequest } from '../auth/scope';
import { ReportsService } from '../reports/reports.service';

@Controller()
@UseGuards(JwtGuard, AccessGuard)
export class AdminController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly updates: UpdatesService,
    private readonly reports: ReportsService,
  ) {}

  @Get('establishments')
  establishments(@Req() req: AuthedRequest) {
    return this.prisma.establishment.findMany({
      where:
        req.user?.role === 'SUPER_ADMIN'
          ? undefined
          : { id: req.user?.establishmentId ?? '__none__' },
      orderBy: { name: 'asc' },
    });
  }

  @Get('admin/app-versions')
  appVersions() {
    return this.prisma.appVersion.findMany({ orderBy: { createdAt: 'desc' } });
  }

  @Post('admin/app-versions')
  async createAppVersion(
    @Body() body: any,
    @Req() req: { user: { sub: string } },
  ) {
    const version = await this.prisma.appVersion.create({
      data: {
        version: body.version,
        buildNumber: Number(body.buildNumber),
        platform: body.platform ?? 'android',
        downloadUrl: body.downloadUrl,
        notes: body.notes,
        minBuild: Number(body.minBuild ?? 1),
        forceUpdate: Boolean(body.forceUpdate),
        status: body.publish ? 'PUBLIEE' : 'BROUILLON',
        publishedAt: body.publish ? new Date() : null,
      },
    });
    await this.audit(req.user.sub, 'CREER', 'APK', `Version ${version.version} (${version.status})`);
    return version;
  }

  @Post('admin/app-versions/:id/publish')
  async publishAppVersion(
    @Param('id') id: string,
    @Req() req: { user: { sub: string } },
  ) {
    const version = await this.prisma.appVersion.update({
      where: { id },
      data: { status: 'PUBLIEE', publishedAt: new Date() },
    });
    await this.audit(req.user.sub, 'PUBLIER', 'APK', `Publication APK ${version.version}`);
    return version;
  }

  @Get('admin/publications')
  publications(@Query('establishmentId') establishmentId?: string) {
    return this.prisma.publication.findMany({
      where: establishmentId ? { establishmentId } : undefined,
      include: { author: { select: { name: true } }, establishment: true },
      orderBy: { createdAt: 'desc' },
    });
  }

  @Post('admin/publications')
  async createPublication(
    @Body() body: { establishmentId: string; type?: string },
    @Req() req: { user: { sub: string } },
  ) {
    const live = await this.updates.liveCatalog(body.establishmentId);
    const count = await this.prisma.publication.count();
    const code = `PUB-${new Date().toISOString().slice(0, 10).replace(/-/g, '')}-${String(count + 1).padStart(3, '0')}`;
    const snapshot = JSON.stringify({
      categories: live.categories,
      products: live.products,
    });
    const publication = await this.prisma.publication.create({
      data: {
        code,
        type: body.type ?? 'CATALOGUE',
        status: 'BROUILLON',
        snapshot,
        hash: live.hash,
        establishmentId: body.establishmentId,
        authorId: req.user.sub,
      },
      include: { author: { select: { name: true } }, establishment: true },
    });
    await this.audit(req.user.sub, 'CREER', 'PUBLICATION', `Brouillon ${code}`);
    return publication;
  }

  @Post('admin/publications/:id/publish')
  async publish(
    @Param('id') id: string,
    @Req() req: { user: { sub: string } },
  ) {
    const publication = await this.prisma.publication.update({
      where: { id },
      data: { status: 'PUBLIEE', publishedAt: new Date() },
      include: { author: { select: { name: true } }, establishment: true },
    });
    await this.prisma.deviceDeployment.updateMany({
      where: { establishmentId: publication.establishmentId },
      data: { status: 'EN_ATTENTE', catalogVersion: publication.code },
    });
    await this.audit(
      req.user.sub,
      'PUBLIER',
      'CATALOGUE',
      `${publication.code} publié pour ${publication.establishment.name}`,
    );
    return publication;
  }

  @Post('admin/publications/:id/rollback')
  async rollback(
    @Param('id') id: string,
    @Req() req: { user: { sub: string } },
  ) {
    const current = await this.prisma.publication.findUnique({ where: { id } });
    if (!current) {
      return { error: 'Publication introuvable' };
    }
    const previous = await this.prisma.publication.findFirst({
      where: {
        establishmentId: current.establishmentId,
        type: 'CATALOGUE',
        status: 'PUBLIEE',
        id: { not: id },
      },
      orderBy: { publishedAt: 'desc' },
    });
    await this.prisma.publication.update({
      where: { id },
      data: { status: 'RESTAUREE' },
    });
    if (previous) {
      await this.prisma.publication.update({
        where: { id: previous.id },
        data: { status: 'PUBLIEE', publishedAt: new Date() },
      });
    }
    await this.audit(req.user.sub, 'ROLLBACK', 'CATALOGUE', `Retour arrière depuis ${current.code}`);
    return { rolledBack: current.code, restored: previous?.code ?? null };
  }

  @Get('admin/remote-config')
  async remoteConfig(@Query('establishmentId') establishmentId: string) {
    return this.updates.config(establishmentId);
  }

  @Put('admin/remote-config')
  async saveConfig(
    @Body() body: { establishmentId: string; values: Record<string, string> },
    @Req() req: { user: { sub: string } },
  ) {
    for (const [key, value] of Object.entries(body.values ?? {})) {
      await this.prisma.remoteConfig.upsert({
        where: {
          establishmentId_key: { establishmentId: body.establishmentId, key },
        },
        update: { value: String(value) },
        create: {
          establishmentId: body.establishmentId,
          key,
          value: String(value),
        },
      });
    }
    await this.audit(req.user.sub, 'MODIFIER', 'CONFIG', 'Configuration distante mise à jour');
    return this.updates.config(body.establishmentId);
  }

  @Get('admin/deployments')
  deployments(@Query('establishmentId') establishmentId?: string) {
    return this.prisma.deviceDeployment.findMany({
      where: establishmentId ? { establishmentId } : undefined,
      include: { establishment: true },
      orderBy: { lastSeenAt: 'desc' },
    });
  }

  @Post('admin/deployments/heartbeat')
  heartbeat(
    @Body()
    body: {
      establishmentId: string;
      deviceName: string;
      role: string;
      appBuild: number;
      catalogVersion?: string;
    },
  ) {
    return this.prisma.deviceDeployment.upsert({
      where: {
        id: createHash('sha1')
          .update(`${body.establishmentId}:${body.deviceName}`)
          .digest('hex')
          .slice(0, 24),
      },
      update: {
        appBuild: body.appBuild,
        catalogVersion: body.catalogVersion,
        status: 'A_JOUR',
        lastSeenAt: new Date(),
      },
      create: {
        id: createHash('sha1')
          .update(`${body.establishmentId}:${body.deviceName}`)
          .digest('hex')
          .slice(0, 24),
        deviceName: body.deviceName,
        role: body.role,
        appBuild: body.appBuild,
        catalogVersion: body.catalogVersion,
        establishmentId: body.establishmentId,
        status: 'A_JOUR',
      },
    });
  }

  @Get('admin/notifications')
  @RequirePermission('rapports.voir', 'systeme.voir')
  notifications() {
    return this.prisma.notificationLog.findMany({
      include: { order: { select: { number: true } } },
      orderBy: { createdAt: 'desc' },
      take: 30,
    });
  }

  @Get('admin/audits')
  @RequirePermission('rapports.voir')
  audits() {
    return this.prisma.auditLog.findMany({
      include: { user: { select: { name: true } } },
      orderBy: { createdAt: 'desc' },
      take: 40,
    });
  }

  @Get('admin/dashboard')
  @RequirePermission('rapports.voir')
  dashboard(@Query('establishmentId') establishmentId: string) {
    return this.reports.dashboard(establishmentId || undefined);
  }

  private audit(userId: string, action: string, entity: string, details: string) {
    return this.prisma.auditLog.create({
      data: { userId, action, entity, details },
    });
  }
}
