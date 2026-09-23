import { BadRequestException, Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { WhatsAppService } from '../notifications/whatsapp.service';
import { TrackingGateway } from '../tracking/tracking.gateway';
import { destinationOf, estimateEta, mapBrowseUrl, mapEmbedUrl, mapUrl } from '../tracking/geo';
import { createTrackingToken } from '../tracking/token';
import { AuthedRequest, mustExist } from '../auth/scope';

const driverSelect = {
  id: true,
  name: true,
  phone: true,
  photoUrl: true,
  availability: true,
  status: true,
} as const;

function withDriverPhoto<T extends { name: string; photoUrl?: string | null }>(driver: T): T {
  if (driver.photoUrl) return driver;
  const name = encodeURIComponent(driver.name);
  return {
    ...driver,
    photoUrl: `https://ui-avatars.com/api/?name=${name}&background=1B5E20&color=fff`,
  };
}

@Injectable()
export class DeliveryService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly whatsapp: WhatsAppService,
    private readonly live: TrackingGateway,
  ) {}

  async drivers(establishmentId: string) {
    const rows = await this.prisma.user.findMany({
      where: { establishmentId, role: 'LIVREUR' },
      select: {
        ...driverSelect,
        establishment: { select: { id: true, name: true, code: true } },
      },
      orderBy: { name: 'asc' },
    });
    return rows.map((row) => withDriverPhoto(row));
  }

  async driverHistory(id: string) {
    const driver = mustExist(
      await this.prisma.user.findUnique({
        where: { id },
        select: {
          ...driverSelect,
          establishment: { select: { id: true, name: true, code: true } },
        },
      }),
      'Livreur introuvable',
    );
    const orders = await this.prisma.order.findMany({
      where: { driverId: id, type: 'LIVRAISON' },
      orderBy: { createdAt: 'desc' },
      include: {
        deliveredBy: { select: { id: true, name: true } },
        establishment: { select: { name: true, address: true } },
      },
    });
    const locations = await this.prisma.driverLocation.findMany({
      where: { driverId: id },
      orderBy: { recordedAt: 'asc' },
      take: 400,
    });
    const trailByOrder = groupTrailByOrder(locations);
    const last = locations.length ? locations[locations.length - 1] : null;
    const latestDest = orders[0] ? destinationOf(orders[0]) : { latitude: -11.664, longitude: 27.479, label: 'Lubumbashi' };
    const courses = orders.map((order) =>
      this.courseSummary(order, trailByOrder.get(order.id) ?? []),
    );
    return {
      ...withDriverPhoto(driver),
      stats: {
        total: courses.length,
        delivered: courses.filter((item) => item.status === 'LIVREE').length,
        active: courses.filter((item) =>
          ['PRETE', 'EN_LIVRAISON'].includes(item.status),
        ).length,
      },
      lastLocation: last ? pointJson(last) : null,
      trail: downsample(locations).map(pointJson),
      destination: latestDest,
      mapUrl: mapEmbedUrl(last, latestDest),
      mapBrowseUrl: mapBrowseUrl(last, latestDest),
      courses,
      movements: [
        ...downsample(locations).map((point) => ({
          at: point.recordedAt,
          label: 'Position GPS',
          kind: 'GPS' as const,
          latitude: point.latitude,
          longitude: point.longitude,
          orderId: point.orderId,
        })),
        ...courses.flatMap((course) =>
          course.movements
            .filter((item) => item.kind === 'STATUS')
            .map((item) => ({ ...item, label: `${course.number} · ${item.label}` })),
        ),
      ].sort((a, b) => new Date(a.at).getTime() - new Date(b.at).getTime()),
    };
  }

  async list(establishmentId: string) {
    const orders = await this.prisma.order.findMany({
      where: { establishmentId, type: 'LIVRAISON' },
      include: {
        items: true,
        driver: { select: driverSelect },
        deliveredBy: { select: { id: true, name: true } },
        establishment: { select: { name: true, address: true } },
      },
      orderBy: { createdAt: 'desc' },
    });
    const locations = await this.prisma.driverLocation.findMany({
      where: { orderId: { in: orders.map((order) => order.id) } },
      orderBy: { recordedAt: 'asc' },
    });
    const trailByOrder = groupTrailByOrder(locations);
    return orders.map((order) => {
      const trail = trailByOrder.get(order.id) ?? [];
      return this.present(order, trail.length ? trail[trail.length - 1] : null, trail);
    });
  }

  async setAvailability(userId: string, availability: string) {
    if (!['DISPONIBLE', 'EN_LIVRAISON', 'HORS_LIGNE'].includes(availability)) {
      throw new BadRequestException('Statut livreur invalide');
    }
    return this.prisma.user.update({
      where: { id: userId },
      data: { availability },
      select: driverSelect,
    });
  }

  async assign(
    id: string,
    driverId: string | undefined,
    req: AuthedRequest & { user: { sub: string } },
  ) {
    const current = mustExist(
      await this.prisma.order.findUnique({ where: { id } }),
      'Commande introuvable',
    );
    let resolved = driverId;
    if (!resolved) {
      const nearest =
        (await this.prisma.user.findFirst({
          where: {
            role: 'LIVREUR',
            availability: 'DISPONIBLE',
            status: 'ACTIF',
            establishmentId: current.establishmentId,
          },
        })) ??
        (await this.prisma.user.findFirst({
          where: {
            role: 'LIVREUR',
            status: 'ACTIF',
            establishmentId: current.establishmentId,
          },
          orderBy: { name: 'asc' },
        }));
      resolved = nearest?.id;
    }
    if (!resolved) {
      throw new BadRequestException('Aucun livreur dans cet établissement. Créez un compte rôle Livreur.');
    }
    const trackingToken = current.trackingToken ?? createTrackingToken();
    const now = new Date();
    const order = await this.prisma.order.update({
      where: { id },
      data: {
        driverId: resolved,
        status: current.status === 'EN_LIVRAISON' ? current.status : 'PRETE',
        pickedUpAt: current.pickedUpAt ?? now,
        trackingToken,
      },
      include: {
        driver: { select: driverSelect },
        deliveredBy: { select: { id: true, name: true } },
        items: true,
        establishment: { select: { name: true, address: true } },
      },
    });
    await this.prisma.user.update({
      where: { id: resolved },
      data: { availability: 'EN_LIVRAISON' },
    });
    const publicBase = process.env.PUBLIC_BASE_URL ?? 'http://localhost:3000';
    await this.whatsapp.notify({
      orderId: order.id,
      event: 'LIVREUR_AFFECTE',
      title: 'Livreur affecté',
      message: `Votre commande #${order.number} est confiée à ${order.driver?.name ?? 'un livreur'}. Suivi : ${publicBase}/track/${order.trackingToken}`,
      phone: order.customerPhone,
    });
    if (order.trackingToken) {
      this.live.emitStatus(order.trackingToken, {
        status: order.status,
        statusLabel: 'Prête — livreur affecté',
        driver: order.driver?.name,
        pickedUpAt: order.pickedUpAt,
      });
    }
    await this.audit(
      req.user.sub,
      'AFFECTER',
      order,
      `${order.number} -> ${order.driver?.name ?? ''}`,
    );
    return this.present(order, null);
  }

  async start(id: string, req: AuthedRequest & { user: { sub: string } }) {
    const current = mustExist(
      await this.prisma.order.findUnique({ where: { id } }),
      'Commande introuvable',
    );
    if (!current.driverId) {
      throw new BadRequestException('Aucun livreur affecté');
    }
    const now = new Date();
    const order = await this.prisma.order.update({
      where: { id },
      data: {
        status: 'EN_LIVRAISON',
        pickedUpAt: current.pickedUpAt ?? now,
        departedAt: current.departedAt ?? now,
      },
      include: {
        driver: { select: driverSelect },
        deliveredBy: { select: { id: true, name: true } },
        items: true,
        establishment: { select: { name: true, address: true } },
      },
    });
    await this.whatsapp.notify({
      orderId: order.id,
      event: 'SUIVI',
      title: 'Livraison',
      message: `Votre commande #${order.number} est en route.`,
      phone: order.customerPhone,
    });
    if (order.trackingToken) {
      this.live.emitStatus(order.trackingToken, {
        status: order.status,
        statusLabel: 'En livraison',
        departedAt: order.departedAt,
      });
    }
    await this.audit(req.user.sub, 'DEPART', order, order.number);
    return this.present(order, null);
  }

  async arrive(id: string, req: AuthedRequest & { user: { sub: string } }) {
    const current = mustExist(
      await this.prisma.order.findUnique({ where: { id } }),
      'Commande introuvable',
    );
    const order = await this.prisma.order.update({
      where: { id },
      data: { arrivedAt: current.arrivedAt ?? new Date() },
      include: {
        driver: { select: driverSelect },
        deliveredBy: { select: { id: true, name: true } },
        items: true,
        establishment: { select: { name: true, address: true } },
      },
    });
    if (order.trackingToken) {
      this.live.emitStatus(order.trackingToken, {
        status: order.status,
        arrivedAt: order.arrivedAt,
      });
    }
    await this.audit(req.user.sub, 'ARRIVEE', order, order.number);
    return this.present(order, null);
  }

  async sendOtp(id: string, req: AuthedRequest & { user: { sub: string; role: string } }) {
    const current = mustExist(
      await this.prisma.order.findUnique({ where: { id } }),
      'Commande introuvable',
    );
    const otp = current.otp ?? String(Math.floor(1000 + Math.random() * 9000));
    const order = await this.prisma.order.update({
      where: { id },
      data: {
        otp,
        otpSentAt: new Date(),
      },
    });
    const log = await this.whatsapp.notify({
      orderId: order.id,
      event: 'OTP',
      title: 'Code de réception',
      message: `Votre code de réception NDJO TACOS pour la commande #${order.number} est : ${otp}. Donnez ce code au livreur à la remise.`,
      phone: order.customerPhone,
    });
    await this.prisma.notificationLog.create({
      data: {
        channel: 'SUIVI_CLIENT',
        title: 'OTP mis à disposition',
        message: `Code de réception publié sur le lien de suivi de ${order.number}.`,
        status: 'ENVOYE',
        orderId: order.id,
      },
    });
    await this.audit(
      req.user.sub,
      'OTP_ENVOYE',
      order,
      `${order.number} -> ${maskPhone(order.customerPhone)} · ${log.status}`,
    );
    return {
      sent: log.status === 'ENVOYE',
      channel: log.status === 'ENVOYE' ? 'WHATSAPP' : 'SUIVI_CLIENT',
      status: log.status,
      phoneMasked: maskPhone(order.customerPhone),
      otpHint: `**${otp.slice(-2)}`,
      otpSentAt: order.otpSentAt,
      receptionReady: true,
      staffOtp: req.user.role === 'LIVREUR' ? undefined : otp,
      error: log.status === 'ENVOYE' ? undefined : log.error,
    };
  }

  async deliver(
    id: string,
    body: {
      otp?: string;
      proofPhotoUrl?: string;
      proofSignature?: string;
      latitude?: number;
      longitude?: number;
    },
    req: AuthedRequest & { user: { sub: string } },
  ) {
    const current = mustExist(
      await this.prisma.order.findUnique({ where: { id } }),
      'Commande introuvable',
    );
    if (current.status === 'LIVREE' || current.otpVerifiedAt) {
      throw new BadRequestException('OTP déjà utilisé');
    }
    if (!current.otp) {
      throw new BadRequestException('Aucun OTP généré pour cette livraison');
    }
    const typed = String(body.otp ?? '').trim();
    if (!typed) {
      throw new BadRequestException('OTP obligatoire');
    }
    if (typed !== current.otp) {
      await this.audit(req.user.sub, 'OTP_REFUSE', current, `${current.number} · saisie incorrecte`);
      throw new BadRequestException('OTP incorrect');
    }
    const now = new Date();
    const order = await this.prisma.order.update({
      where: { id },
      data: {
        status: 'LIVREE',
        paymentStatus: current.paymentStatus === 'PAYE' ? 'PAYE' : 'EN_ATTENTE',
        otpVerifiedAt: now,
        deliveredAt: now,
        arrivedAt: current.arrivedAt ?? now,
        deliveredLat: body.latitude != null ? Number(body.latitude) : current.deliveredLat,
        deliveredLng: body.longitude != null ? Number(body.longitude) : current.deliveredLng,
        proofPhotoUrl: body.proofPhotoUrl ?? current.proofPhotoUrl,
        proofSignature: body.proofSignature ?? current.proofSignature,
        deliveredById: req.user.sub,
      },
      include: {
        driver: { select: driverSelect },
        deliveredBy: { select: { id: true, name: true } },
        items: true,
        payments: true,
        establishment: { select: { name: true, address: true } },
      },
    });
    if (order.driverId) {
      await this.prisma.user.update({
        where: { id: order.driverId },
        data: { availability: 'DISPONIBLE' },
      });
    }
    await this.whatsapp.notify({
      orderId: order.id,
      event: 'LIVREE',
      title: 'Livraison terminée',
      message: `Votre commande #${order.number} a été livrée. Paiement : ${order.paymentStatus}.`,
      phone: order.customerPhone,
    });
    if (order.trackingToken) {
      this.live.emitStatus(order.trackingToken, {
        status: order.status,
        statusLabel: 'Livrée',
        delivered: true,
        deliveredAt: order.deliveredAt,
      });
    }
    await this.audit(req.user.sub, 'OTP_VALIDE', order, order.number);
    await this.audit(req.user.sub, 'LIVREE', order, order.number);
    return this.present(order, null);
  }

  async recordLocation(
    body: { latitude: number; longitude: number; orderId?: string },
    userId: string,
  ) {
    if (body.latitude == null || body.longitude == null) {
      throw new BadRequestException('Coordonnées GPS requises');
    }
    const point = await this.prisma.driverLocation.create({
      data: {
        driverId: userId,
        orderId: body.orderId,
        latitude: Number(body.latitude),
        longitude: Number(body.longitude),
      },
    });
    let eta: ReturnType<typeof estimateEta> | null = null;
    let destination: ReturnType<typeof destinationOf> | null = null;
    if (body.orderId) {
      const order = await this.prisma.order.findUnique({
        where: { id: body.orderId },
        include: { establishment: { select: { address: true } } },
      });
      if (order && order.status !== 'LIVREE') {
        destination = destinationOf(order);
        eta = estimateEta(point.latitude, point.longitude, destination.latitude, destination.longitude);
        if (order.trackingToken) {
          this.live.emitLocation(order.trackingToken, {
            latitude: point.latitude,
            longitude: point.longitude,
            recordedAt: point.recordedAt,
            eta,
            destination,
          });
        }
      }
    }
    return {
      ...point,
      eta,
      destination,
    };
  }

  present(
    order: {
      id: string;
      number: string;
      status: string;
      paymentStatus: string;
      customerName: string | null;
      customerPhone: string | null;
      address: string | null;
      zone: string | null;
      deliveryFee: number;
      total: number;
      driverId: string | null;
      trackingToken: string | null;
      pickedUpAt: Date | null;
      departedAt: Date | null;
      arrivedAt: Date | null;
      deliveredAt: Date | null;
      deliveredLat: number | null;
      deliveredLng: number | null;
      proofPhotoUrl: string | null;
      proofSignature: string | null;
      otpSentAt: Date | null;
      otpVerifiedAt: Date | null;
      createdAt: Date;
      items?: unknown;
      driver?: unknown;
      deliveredBy?: unknown;
      establishment?: { name?: string; address?: string | null } | null;
    },
    location: { latitude: number; longitude: number; recordedAt: Date } | null,
    trail: { latitude: number; longitude: number; recordedAt: Date }[] = [],
  ) {
    const dest = destinationOf(order);
    const eta =
      location && dest
        ? estimateEta(location.latitude, location.longitude, dest.latitude, dest.longitude)
        : null;
    return {
      id: order.id,
      number: order.number,
      status: order.status,
      paymentStatus: order.paymentStatus,
      customerName: order.customerName,
      customerPhone: order.customerPhone,
      address: order.address,
      zone: order.zone,
      deliveryFee: order.deliveryFee,
      total: order.total,
      driverId: order.driverId,
      trackingToken: order.trackingToken,
      pickedUpAt: order.pickedUpAt,
      departedAt: order.departedAt,
      arrivedAt: order.arrivedAt,
      deliveredAt: order.deliveredAt,
      durationMinutes: durationMinutes(order.departedAt, order.arrivedAt ?? order.deliveredAt),
      otpSent: Boolean(order.otpSentAt),
      otpSentAt: order.otpSentAt,
      otpVerifiedAt: order.otpVerifiedAt,
      proof: {
        photoUrl: order.proofPhotoUrl,
        signature: order.proofSignature,
        deliveredAt: order.deliveredAt,
        latitude: order.deliveredLat,
        longitude: order.deliveredLng,
        deliveredBy: order.deliveredBy ?? null,
      },
      driver: order.driver
        ? withDriverPhoto(order.driver as { name: string; photoUrl?: string | null })
        : null,
      items: order.items ?? [],
      destination: dest,
      location: location
        ? {
            latitude: location.latitude,
            longitude: location.longitude,
            recordedAt: location.recordedAt,
          }
        : null,
      eta,
      trail: downsample(trail).map(pointJson),
      movements: movementHistory(order, trail),
      mapUrl: mapUrl(location, dest),
      mapBrowseUrl: mapBrowseUrl(location, dest),
    };
  }

  private courseSummary(
    order: {
      id: string;
      number: string;
      status: string;
      address: string | null;
      zone?: string | null;
      customerName: string | null;
      pickedUpAt: Date | null;
      departedAt: Date | null;
      arrivedAt: Date | null;
      deliveredAt: Date | null;
      deliveredLat?: number | null;
      deliveredLng?: number | null;
      total: number;
      createdAt: Date;
      deliveredBy?: { id: string; name: string } | null;
      establishment?: { name?: string; address?: string | null } | null;
    },
    trail: { latitude: number; longitude: number; recordedAt: Date }[] = [],
  ) {
    const dest = destinationOf(order);
    const last = trail.length ? trail[trail.length - 1] : null;
    return {
      id: order.id,
      number: order.number,
      status: order.status,
      customerName: order.customerName,
      address: order.address,
      createdAt: order.createdAt,
      pickedUpAt: order.pickedUpAt,
      departedAt: order.departedAt,
      arrivedAt: order.arrivedAt,
      deliveredAt: order.deliveredAt,
      durationMinutes: durationMinutes(order.departedAt, order.arrivedAt ?? order.deliveredAt),
      total: order.total,
      deliveredBy: order.deliveredBy ?? null,
      destination: dest,
      location: last ? pointJson(last) : null,
      trail: downsample(trail).map(pointJson),
      movements: movementHistory(order, trail),
      mapUrl: mapEmbedUrl(last, dest),
      mapBrowseUrl: mapBrowseUrl(last, dest),
    };
  }

  private async audit(
    userId: string,
    action: string,
    order: { id: string; establishmentId?: string; number?: string },
    details: string,
  ) {
    try {
      await this.prisma.auditLog.create({
        data: {
          userId,
          action,
          entity: 'LIVRAISON',
          entityId: order.id,
          details,
          establishmentId: order.establishmentId,
        },
      });
    } catch (_) {}
  }
}

function maskPhone(phone?: string | null) {
  if (!phone) return null;
  const digits = phone.replace(/\s+/g, '');
  if (digits.length < 4) return '****';
  return `${digits.slice(0, 5)}****${digits.slice(-2)}`;
}

function durationMinutes(from?: Date | null, to?: Date | null) {
  if (!from || !to) return null;
  return Math.max(0, Math.round((to.getTime() - from.getTime()) / 60000));
}

type GpsPoint = { latitude: number; longitude: number; recordedAt: Date; orderId?: string | null };

function pointJson(point: GpsPoint) {
  return {
    latitude: point.latitude,
    longitude: point.longitude,
    recordedAt: point.recordedAt,
  };
}

function groupTrailByOrder(locations: GpsPoint[]) {
  const trailByOrder = new Map<string, GpsPoint[]>();
  for (const point of locations) {
    if (!point.orderId) continue;
    const list = trailByOrder.get(point.orderId) ?? [];
    list.push(point);
    trailByOrder.set(point.orderId, list);
  }
  return trailByOrder;
}

function downsample<T>(items: T[], max = 80): T[] {
  if (items.length <= max) return items;
  const step = Math.ceil(items.length / max);
  return items.filter((_, index) => index % step === 0 || index === items.length - 1);
}

function movementHistory(
  order: {
    createdAt?: Date | null;
    pickedUpAt: Date | null;
    departedAt: Date | null;
    arrivedAt: Date | null;
    deliveredAt: Date | null;
    deliveredLat?: number | null;
    deliveredLng?: number | null;
    status?: string | null;
  },
  trail: GpsPoint[],
) {
  const events: {
    at: Date;
    label: string;
    kind: 'STATUS' | 'GPS';
    latitude?: number;
    longitude?: number;
  }[] = [];
  if (order.createdAt) {
    events.push({ at: order.createdAt, label: 'Commande créée', kind: 'STATUS' });
  }
  if (order.pickedUpAt) {
    events.push({ at: order.pickedUpAt, label: 'Prise en charge', kind: 'STATUS' });
  }
  if (order.departedAt) {
    events.push({ at: order.departedAt, label: 'Départ', kind: 'STATUS' });
  }
  for (const point of trail) {
    events.push({
      at: point.recordedAt,
      label: 'Position GPS',
      kind: 'GPS',
      latitude: point.latitude,
      longitude: point.longitude,
    });
  }
  if (order.arrivedAt) {
    events.push({ at: order.arrivedAt, label: 'Arrivée client', kind: 'STATUS' });
  }
  if (order.deliveredAt) {
    events.push({
      at: order.deliveredAt,
      label: 'Livrée',
      kind: 'STATUS',
      latitude: order.deliveredLat ?? undefined,
      longitude: order.deliveredLng ?? undefined,
    });
  }
  if (events.length === 0) {
    events.push({
      at: new Date(),
      label: order.status ? `En cours · ${order.status}` : 'En attente de mouvement',
      kind: 'STATUS',
    });
  }
  return events.sort((a, b) => a.at.getTime() - b.at.getTime());
}
