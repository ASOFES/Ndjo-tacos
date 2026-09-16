import { io } from 'socket.io-client';

const base = process.env.API_URL ?? 'http://localhost:3000';

async function request(path, { method = 'GET', body, token, accept } = {}) {
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(accept ? { Accept: accept } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  return { status: response.status, text, json };
}

function line(key, value) {
  console.log(`${key}=${value}`);
}

const proofs = {};

try {
  const noToken = await request('/track');
  proofs.NO_TOKEN = noToken.status;
  line('NO_TOKEN', noToken.status);

  const wrong = await request('/track/not-a-real-token-xx');
  proofs.WRONG_TOKEN = wrong.status;
  line('WRONG_TOKEN', wrong.status);

  const auth = await request('/auth/login', {
    method: 'POST',
    body: { username: 'admin', password: 'admin123' },
  });
  const access = auth.json?.token;
  if (!access) throw new Error('login failed');

  const me = await request('/auth/me', { token: access });
  const establishmentId = me.json?.establishment?.id ?? me.json?.establishmentId;
  const catalog = await request(
    `/catalog/products?establishmentId=${establishmentId}&kind=VENTE`,
    { token: access },
  );
  const product = (catalog.json ?? []).find((item) => (item.stockQty ?? 0) > 0) ?? (catalog.json ?? [])[0];
  if (!product) throw new Error('no product');

  const created = await request('/orders', {
    method: 'POST',
    token: access,
    body: {
      establishmentId,
      type: 'LIVRAISON',
      address: 'Kenya, Lubumbashi',
      zone: 'Kenya',
      customerName: 'Client suivi',
      customerPhone: '243800000001',
      items: [{ productId: product.id, quantity: 1 }],
    },
  });
  const order = created.json;
  if (!order?.id) throw new Error(created.json?.message ?? 'order create failed');
  const trackingToken = order.trackingToken;
  const tokenOk =
    typeof trackingToken === 'string' &&
    trackingToken.length >= 12 &&
    trackingToken !== order.id &&
    !String(order.number).includes(trackingToken);
  proofs.TRACK_TOKEN = tokenOk ? 'OK' : 'FAIL';
  line('TRACK_TOKEN', proofs.TRACK_TOKEN);
  line('TRACK_URL', `${base}/track/${trackingToken}`);

  const page = await request(`/track/${trackingToken}`, { accept: 'text/html' });
  proofs.TRACK_PAGE = page.status;
  line('TRACK_PAGE', page.status);
  const mapOk = page.text.includes('id="map"') && page.text.includes('leaflet');
  proofs.MAP = mapOk ? 'OK' : 'FAIL';
  line('MAP', proofs.MAP);

  const jsonBefore = await request(`/track/${trackingToken}`, { accept: 'application/json' });
  const leaked =
    JSON.stringify(jsonBefore.json ?? {}).includes('paymentStatus') ||
    JSON.stringify(jsonBefore.json ?? {}).includes('"phone"');
  if (leaked) line('SECURITY', 'LEAK');
  if (jsonBefore.json?.etaAvailable === true) line('ETA_BEFORE_GPS', 'UNEXPECTED');

  const drivers = await request(`/delivery/drivers?establishmentId=${establishmentId}`, { token: access });
  const driver = (drivers.json ?? []).find((item) => item.username === 'livreur') ?? (drivers.json ?? [])[0];
  if (driver?.id) {
    await request(`/delivery/${order.id}/assign`, {
      method: 'POST',
      token: access,
      body: { driverId: driver.id },
    });
  } else {
    await request(`/delivery/${order.id}/assign`, { method: 'POST', token: access, body: {} });
  }
  await request(`/delivery/${order.id}/start`, { method: 'POST', token: access, body: {} });

  const wsHits = [];
  const socket = io(`${base}/live`, { transports: ['websocket', 'polling'] });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('websocket connect timeout')), 8000);
    socket.on('connect', () => {
      clearTimeout(timer);
      resolve();
    });
    socket.on('connect_error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
  const ack = await socket.timeout(4000).emitWithAck('track:join', { token: trackingToken });
  if (!ack?.ok) throw new Error(`join failed ${ack?.error ?? ''}`);
  const nextLocation = new Promise((resolve) => {
    socket.on('track:location', (payload) => {
      wsHits.push(payload);
      resolve(payload);
    });
  });

  const gps1 = await request('/delivery/location', {
    method: 'POST',
    token: access,
    body: { latitude: -11.7, longitude: 27.5, orderId: order.id },
  });
  const gps2 = await request('/delivery/location', {
    method: 'POST',
    token: access,
    body: { latitude: -11.665, longitude: 27.48, orderId: order.id },
  });
  await Promise.race([
    nextLocation,
    new Promise((_, reject) => setTimeout(() => reject(new Error('websocket location timeout')), 5000)),
  ]).catch(() => null);

  const jsonAfter = await request(`/track/${trackingToken}`, { accept: 'application/json' });
  const loc = jsonAfter.json?.location;
  const eta = jsonAfter.json?.eta;
  proofs.GPS = loc?.latitude ? 'OK' : 'FAIL';
  proofs.ETA = eta?.minutes ? 'OK' : 'FAIL';
  proofs.WEBSOCKET = wsHits.length > 0 ? 'OK' : 'FAIL';
  line('GPS', proofs.GPS);
  line('ETA', proofs.ETA);
  line('WEBSOCKET', proofs.WEBSOCKET);
  if (eta) line('ETA_MINUTES', eta.minutes);
  if (gps1.json?.eta && gps2.json?.eta) {
    line('ETA_UPDATED', gps2.json.eta.minutes !== gps1.json.eta.minutes ? 'OK' : 'SAME');
  }

  socket.close();
} catch (error) {
  line('ERROR', error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
