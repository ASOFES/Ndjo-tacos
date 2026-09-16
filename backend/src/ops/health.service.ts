import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { WhatsAppService } from '../notifications/whatsapp.service';
import { PaymentService } from '../payments/payment.service';
import { lanInfo } from './lan';

export type HealthLevel = 'VERT' | 'ORANGE' | 'ROUGE' | 'MAINTENANCE';

@Injectable()
export class HealthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly whatsapp: WhatsAppService,
    private readonly payments: PaymentService,
  ) {}

  async snapshot() {
    const flags = await this.prisma.systemFlag.findMany();
    const flagMap = Object.fromEntries(flags.map((row) => [row.key, row]));
    let database: HealthLevel = 'ROUGE';
    let databaseName: string | null = null;
    let databaseVersion: string | null = null;
    try {
      const rows = await this.prisma.$queryRaw<
        Array<{ db: string; version: string }>
      >`SELECT current_database() as db, version() as version`;
      databaseName = rows[0]?.db ?? null;
      databaseVersion = rows[0]?.version ?? null;
      database = 'VERT';
    } catch {
      database = 'ROUGE';
    }

    const stale = new Date(Date.now() - 2 * 60 * 60 * 1000);
    const [pendingDevices, staleDevices, recentGps] = await Promise.all([
      this.prisma.deviceDeployment.count({ where: { pendingOps: { gt: 0 } } }),
      this.prisma.deviceDeployment.count({ where: { lastSeenAt: { lt: stale } } }),
      this.prisma.driverLocation.count({
        where: { recordedAt: { gte: new Date(Date.now() - 10 * 60 * 1000) } },
      }),
    ]);

    const sync: HealthLevel =
      pendingDevices > 0 || staleDevices > 0 ? 'ORANGE' : 'VERT';
    const whatsapp: HealthLevel = this.whatsapp.configured() ? 'VERT' : 'ORANGE';
    const payments: HealthLevel =
      this.payments.operatorConfigured('MOBILE_MONEY') &&
      this.payments.operatorConfigured('CARTE')
        ? 'VERT'
        : 'ORANGE';
    const gps: HealthLevel = recentGps > 0 ? 'VERT' : 'ROUGE';

    const override = (key: string, computed: HealthLevel): HealthLevel =>
      (flagMap[key]?.status as HealthLevel) ?? computed;

    return {
      generatedAt: new Date().toISOString(),
      services: {
        api: override('api', 'VERT'),
        database: override('database', database),
        sync: override('sync', sync),
        whatsapp: override('whatsapp', whatsapp),
        payments: override('payments', payments),
        gps: override('gps', gps),
      },
      details: {
        pendingDevices,
        staleDevices,
        recentGps,
        whatsappConfigured: this.whatsapp.configured(),
        whatsappWebhookReady: Boolean(process.env.WHATSAPP_APP_SECRET && process.env.WHATSAPP_VERIFY_TOKEN),
        mobileMoneyConfigured: this.payments.operatorConfigured('MOBILE_MONEY'),
        cardConfigured: this.payments.operatorConfigured('CARTE'),
        flexpayConfigured: Boolean(process.env.FLEXPAY_TOKEN && process.env.FLEXPAY_MERCHANT),
        stripeConfigured: Boolean(process.env.STRIPE_SECRET_KEY),
        databaseProvider: process.env.DATABASE_URL?.startsWith('postgres')
          ? 'postgresql'
          : 'sqlite',
        databaseName,
        databaseVersion,
        jwtAccessTtl: process.env.JWT_ACCESS_TTL ?? '7d',
        httpsRequired: process.env.NODE_ENV === 'production',
        lan: lanInfo(Number(process.env.PORT ?? 3000), Number(process.env.WEB_PORT ?? 5192)),
      },
      flags,
    };
  }
}
