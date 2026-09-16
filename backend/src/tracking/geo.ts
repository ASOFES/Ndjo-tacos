export type GeoPoint = {
  latitude: number;
  longitude: number;
  label?: string;
};

function finite(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

export function destinationOf(order: {
  establishment?: { address?: string | null } | null;
  address?: string | null;
  zone?: string | null;
}): GeoPoint {
  const text = `${order.address ?? ''} ${order.zone ?? ''} ${order.establishment?.address ?? ''}`.toLowerCase();
  if (text.includes('kenya')) {
    return { latitude: -11.687, longitude: 27.492, label: order.address || 'Kenya' };
  }
  return { latitude: -11.664, longitude: 27.479, label: order.address || 'Centre-ville' };
}

export function distanceKm(lat1: number, lon1: number, lat2: number, lon2: number) {
  const toRad = (value: number) => (value * Math.PI) / 180;
  const earth = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return earth * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export function estimateEta(
  lat1: unknown,
  lon1: unknown,
  lat2: unknown,
  lon2: unknown,
) {
  if (!finite(lat1) || !finite(lon1) || !finite(lat2) || !finite(lon2)) {
    return null;
  }
  const km = distanceKm(lat1, lon1, lat2, lon2);
  if (!Number.isFinite(km)) return null;
  return {
    distanceKm: Math.round(km * 10) / 10,
    minutes: Math.max(1, Math.round((km / 25) * 60)),
    note: 'Estimé à 25 km/h en ville.',
  };
}

const LUBUMBASHI: GeoPoint = { latitude: -11.664, longitude: 27.479, label: 'Lubumbashi' };

function usable(point?: GeoPoint | null): point is GeoPoint {
  return point != null && finite(point.latitude) && finite(point.longitude);
}

export function mapBrowseUrl(location?: GeoPoint | null, dest?: GeoPoint | null) {
  const marker = usable(location) ? location : usable(dest) ? dest : LUBUMBASHI;
  return `https://www.openstreetmap.org/?mlat=${marker.latitude}&mlon=${marker.longitude}#map=15/${marker.latitude}/${marker.longitude}`;
}

export function mapEmbedUrl(location?: GeoPoint | null, dest?: GeoPoint | null) {
  const points = [location, dest].filter(usable);
  const marker = points[0] ?? LUBUMBASHI;
  const lats = points.length ? points.map((point) => point.latitude) : [marker.latitude];
  const lngs = points.length ? points.map((point) => point.longitude) : [marker.longitude];
  const pad = 0.025;
  const south = Math.min(...lats) - pad;
  const north = Math.max(...lats) + pad;
  const west = Math.min(...lngs) - pad;
  const east = Math.max(...lngs) + pad;
  return `https://www.openstreetmap.org/export/embed.html?bbox=${west},${south},${east},${north}&layer=mapnik&marker=${marker.latitude}%2C${marker.longitude}`;
}

export function mapUrl(location: GeoPoint | null | undefined, dest: GeoPoint) {
  return mapEmbedUrl(location, dest);
}
