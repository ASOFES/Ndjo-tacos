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

try {
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
  const created = await request('/orders', {
    method: 'POST',
    token: access,
    body: {
      establishmentId,
      type: 'LIVRAISON',
      method: 'ESPECES',
      address: 'Kenya, Lubumbashi',
      zone: 'Kenya',
      customerName: 'Client OTP',
      customerPhone: '243800000002',
      items: [{ productId: product.id, quantity: 1 }],
    },
  });
  const order = created.json;
  if (!order?.id) throw new Error(created.json?.message ?? 'order create failed');
  const trackingToken = order.trackingToken;

  const drivers = await request(`/delivery/drivers?establishmentId=${establishmentId}`, { token: access });
  const driver = (drivers.json ?? [])[0];
  await request(`/delivery/${order.id}/assign`, {
    method: 'POST',
    token: access,
    body: driver?.id ? { driverId: driver.id } : {},
  });
  await request(`/delivery/${order.id}/start`, { method: 'POST', token: access, body: {} });

  const payBefore = await request(`/payments/order/${order.id}`, { token: access });
  const pendingPay = (payBefore.json?.payments ?? []).find((item) => item.status === 'EN_ATTENTE');
  line('COD_BEFORE_DELIVER', payBefore.json?.paymentStatus ?? 'MISSING');
  line('COD_PENDING_ROW', pendingPay ? 'OK' : 'FAIL');

  const collectEarly = await request(`/delivery/${order.id}/collect`, {
    method: 'POST',
    token: access,
    body: { received: order.total },
  });
  line('COLLECT_BEFORE_OTP', collectEarly.status);

  const otpRes = await request(`/delivery/${order.id}/send-otp`, { method: 'POST', token: access, body: {} });
  const otp = otpRes.json?.staffOtp;
  if (!otp) throw new Error('staff OTP missing');

  const bad = await request(`/delivery/${order.id}/deliver`, {
    method: 'POST',
    token: access,
    body: { otp: '0000', proofSignature: 'x' },
  });
  line('BAD_OTP', bad.status === 400 ? 'REFUSED' : `FAIL:${bad.status}`);

  const socket = io(`${base}/live`, { transports: ['websocket', 'polling'] });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('ws connect timeout')), 8000);
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
  if (!ack?.ok) throw new Error('join failed');
  const deliveredEvent = new Promise((resolve) => {
    socket.on('track:status', (payload) => {
      if (payload.status === 'LIVREE' || payload.delivered === true) resolve(payload);
    });
  });

  const ok = await request(`/delivery/${order.id}/deliver`, {
    method: 'POST',
    token: access,
    body: { otp, proofSignature: 'client' },
  });
  line('DELIVER', ok.json?.status === 'LIVREE' ? 'LIVREE' : `FAIL:${ok.json?.status ?? ok.status}`);
  line('PAY_AFTER_OTP', ok.json?.paymentStatus ?? 'MISSING');

  const reuse = await request(`/delivery/${order.id}/deliver`, {
    method: 'POST',
    token: access,
    body: { otp, proofSignature: 'client' },
  });
  const reuseMsg = String(reuse.json?.message ?? '');
  line('OTP_REUSE', reuse.status === 400 && /déjà utilisé/i.test(reuseMsg) ? 'REFUSED' : `FAIL:${reuse.status}`);

  const ws = await Promise.race([
    deliveredEvent,
    new Promise((_, reject) => setTimeout(() => reject(new Error('ws LIVREE timeout')), 5000)),
  ]).catch(() => null);
  line('WS_LIVREE', ws ? 'OK' : 'FAIL');

  const page = await request(`/track/${trackingToken}`, { accept: 'application/json' });
  line('TRACK_STATUS', page.json?.status ?? 'MISSING');
  line('TRACK_DELIVERED', page.json?.delivered === true ? 'OK' : 'FAIL');
  line('TRACK_PAY_LEAK', JSON.stringify(page.json ?? {}).includes('paymentStatus') ? 'LEAK' : 'OK');

  const collect = await request(`/delivery/${order.id}/collect`, {
    method: 'POST',
    token: access,
    body: { received: order.total },
  });
  line('COLLECT', collect.json?.paymentStatus === 'PAYE' ? 'PAYE' : `FAIL:${collect.json?.paymentStatus ?? collect.status}`);
  const confirmed = (collect.json?.payments ?? []).find((item) => item.status === 'CONFIRME');
  line('COD_CONFIRMED_ROW', confirmed ? 'OK' : 'FAIL');

  socket.close();
} catch (error) {
  line('ERROR', error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
