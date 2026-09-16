import { Injectable } from '@nestjs/common';
import { createHash } from 'crypto';
import { PrismaService } from '../prisma.service';

@Injectable()
export class UpdatesService {
  constructor(private readonly prisma: PrismaService) {}

  async checkApp(platform: string, build: number) {
    const latest = await this.prisma.appVersion.findFirst({
      where: { platform, status: 'PUBLIEE' },
      orderBy: { buildNumber: 'desc' },
    });
    if (!latest || latest.buildNumber <= build) {
      return {
        updateAvailable: false,
        updateRequired: false,
        force: false,
        currentBuild: build,
      };
    }
    return {
      updateAvailable: true,
      updateRequired: build < latest.minBuild || latest.forceUpdate,
      force: latest.forceUpdate || build < latest.minBuild,
      version: latest.version,
      buildNumber: latest.buildNumber,
      url: latest.downloadUrl,
      notes: latest.notes,
      minBuild: latest.minBuild,
    };
  }

  async catalog(establishmentId: string, sinceVersion?: string) {
    const publication = await this.prisma.publication.findFirst({
      where: { establishmentId, type: 'CATALOGUE', status: 'PUBLIEE' },
      orderBy: { publishedAt: 'desc' },
    });
    if (!publication) {
      const live = await this.liveCatalog(establishmentId);
      return { version: null, unchanged: false, ...live };
    }
    if (sinceVersion && sinceVersion === publication.code) {
      return { version: publication.code, unchanged: true, hash: publication.hash };
    }
    return {
      version: publication.code,
      unchanged: false,
      hash: publication.hash,
      publishedAt: publication.publishedAt,
      ...JSON.parse(publication.snapshot),
    };
  }

  async config(establishmentId: string) {
    const rows = await this.prisma.remoteConfig.findMany({
      where: { establishmentId },
    });
    return Object.fromEntries(rows.map((row) => [row.key, row.value]));
  }

  async liveCatalog(establishmentId: string) {
    const [categories, products] = await Promise.all([
      this.prisma.category.findMany({
        where: { establishmentId },
        orderBy: { name: 'asc' },
      }),
      this.prisma.product.findMany({
        where: { establishmentId, status: 'ACTIF' },
        include: { category: true },
        orderBy: { name: 'asc' },
      }),
    ]);
    const snapshot = { categories, products };
    return {
      hash: createHash('sha256').update(JSON.stringify(snapshot)).digest('hex'),
      ...snapshot,
    };
  }
}
