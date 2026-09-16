import { Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { destinationOf, estimateEta, mapBrowseUrl, mapUrl } from './geo';
import { renderTrackHtml } from './track.page';

const STATUS_LABEL: Record<string, string> = {
  EN_CAISSE: 'Reçue — en attente à la caisse',
  NOUVELLE: 'Envoyée en cuisine',
  EN_PREPARATION: 'En préparation',
  PRETE: 'Prête — livreur affecté',
  EN_LIVRAISON: 'En livraison',
  LIVREE: 'Livrée',
  ANNULEE: 'Annulée',
};

@Injectable()
export class TrackingService {
  constructor(private readonly prisma: PrismaService) {}

  async latestLocation(order: {
    id: string;
    driverId: string | null;
    departedAt: Date | null;
    pickedUpAt: Date | null;
    createdAt: Date;
    status: string;
  }) {
    if (order.status === 'LIVREE') {
      const last = await this.prisma.driverLocation.findFirst({
        where: { orderId: order.id },
        orderBy: { recordedAt: 'desc' },
      });
      return last;
    }
    const byOrder = await this.prisma.driverLocation.findFirst({
      where: { orderId: order.id },
      orderBy: { recordedAt: 'desc' },
    });
    if (byOrder) return byOrder;
    if (!order.driverId) return null;
    const since = order.departedAt ?? order.pickedUpAt ?? order.createdAt;
    return this.prisma.driverLocation.findFirst({
      where: {
        driverId: order.driverId,
        recordedAt: { gte: since },
      },
      orderBy: { recordedAt: 'desc' },
    });
  }

  async publicView(token: string) {
    const order = await this.prisma.order.findUnique({
      where: { trackingToken: token },
      include: {
        items: true,
        driver: { select: { name: true, photoUrl: true } },
        establishment: { select: { name: true, address: true } },
      },
    });
    if (!order) throw new NotFoundException('Suivi introuvable');
    const location = await this.latestLocation(order);
    const trail = await this.prisma.driverLocation.findMany({
      where: { orderId: order.id },
      orderBy: { recordedAt: 'asc' },
      take: 80,
    });
    const dest = destinationOf(order);
    const eta =
      location && dest
        ? estimateEta(location.latitude, location.longitude, dest.latitude, dest.longitude)
        : null;
    const lastUpdate = location?.recordedAt ?? order.updatedAt;
    return {
      number: order.number,
      status: order.status,
      statusLabel: STATUS_LABEL[order.status] ?? order.status,
      type: order.type,
      restaurant: {
        name: order.establishment.name,
        address: order.establishment.address,
      },
      destination: {
        label: order.address || dest.label || 'Destination',
        zone: order.zone,
        latitude: dest.latitude,
        longitude: dest.longitude,
      },
      items: order.items.map((item) => ({
        name: item.name,
        quantity: item.quantity,
      })),
      driver: order.driver
        ? {
            name: order.driver.name,
            photoUrl:
              order.driver.photoUrl ??
              `https://ui-avatars.com/api/?name=${encodeURIComponent(order.driver.name)}&background=E85D04&color=fff`,
          }
        : null,
      location: location
        ? {
            latitude: location.latitude,
            longitude: location.longitude,
            recordedAt: location.recordedAt,
          }
        : null,
      eta,
      etaAvailable: Boolean(eta),
      lastUpdate,
      mapUrl: mapUrl(location, dest),
      mapBrowseUrl: mapBrowseUrl(location, dest),
      trail: trail.map((point) => ({
        latitude: point.latitude,
        longitude: point.longitude,
        recordedAt: point.recordedAt,
      })),
      movements: [
        ...(order.pickedUpAt ? [{ at: order.pickedUpAt, label: 'Prise en charge', kind: 'STATUS' }] : []),
        ...(order.departedAt ? [{ at: order.departedAt, label: 'Départ', kind: 'STATUS' }] : []),
        ...trail.map((point) => ({
          at: point.recordedAt,
          label: 'Position GPS',
          kind: 'GPS',
          latitude: point.latitude,
          longitude: point.longitude,
        })),
        ...(order.arrivedAt ? [{ at: order.arrivedAt, label: 'Arrivée client', kind: 'STATUS' }] : []),
        ...(order.deliveredAt
          ? [
              {
                at: order.deliveredAt,
                label: 'Livrée',
                kind: 'STATUS',
                latitude: order.deliveredLat,
                longitude: order.deliveredLng,
              },
            ]
          : []),
      ].sort((a, b) => new Date(a.at).getTime() - new Date(b.at).getTime()),
      trackingToken: token,
      delivered: order.status === 'LIVREE',
      deliveredAt: order.deliveredAt,
    };
  }

  htmlPage(view: Awaited<ReturnType<TrackingService['publicView']>>) {
    return renderTrackHtml(view);
  }
}
