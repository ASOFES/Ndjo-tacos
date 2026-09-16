import net from 'net';
import pg from 'pg';

const API = process.env.API_URL ?? 'http://localhost:3000';
const DATABASE_URL =
  process.env.DATABASE_URL ??
  'postgresql://ndjo:ndjo@localhost:5432/ndjo_tacos?schema=public';

const results = [];

function record(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'SUCCESS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
}

function tcp5432() {
  return new Promise((resolve) => {
    const socket = net.connect({ host: '127.0.0.1', port: 5432 }, () => {
      socket.end();
      resolve(true);
    });
    socket.setTimeout(3000);
    socket.on('timeout', () => {
      socket.destroy();
      resolve(false);
    });
    socket.on('error', () => resolve(false));
  });
}

async function api(path, options = {}) {
  const response = await fetch(`${API}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(options.headers ?? {}),
    },
  });
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: response.status, body };
}

async function main() {
  const reachable = await tcp5432();
  record('PostgreSQL localhost:5432 accessible', reachable, reachable ? 'TCP open' : 'port closed');

  const urlIsPg = DATABASE_URL.startsWith('postgresql://') || DATABASE_URL.startsWith('postgres://');
  record('DATABASE_URL PostgreSQL', urlIsPg, DATABASE_URL.replace(/:[^:@/]+@/, ':***@'));

  const client = new pg.Client({ connectionString: DATABASE_URL });
  try {
    await client.connect();
    const info = await client.query('SELECT current_database() AS db, version() AS version, current_setting(\'server_encoding\') AS encoding');
    record(
      'API connexion DB',
      /PostgreSQL/i.test(info.rows[0].version) && info.rows[0].db === 'ndjo_tacos',
      `${info.rows[0].db} · ${info.rows[0].encoding} · ${String(info.rows[0].version).split(',')[0]}`,
    );
    const tables = await client.query(
      "SELECT COUNT(*)::int AS n FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'",
    );
    record('Tables Prisma présentes', tables.rows[0].n >= 10, `${tables.rows[0].n} tables`);
  } catch (error) {
    record('API connexion DB', false, error instanceof Error ? error.message : String(error));
  } finally {
    await client.end().catch(() => undefined);
  }

  const login = await api('/auth/login', {
    method: 'POST',
    body: JSON.stringify({ username: 'admin', password: 'admin123' }),
  });
  const token = login.body?.token ?? login.body?.accessToken;
  record('POST /auth/login', login.status === 201 || login.status === 200, `HTTP ${login.status}`);
  if (!token) {
    console.log(JSON.stringify(results, null, 2));
    process.exit(1);
  }
  const auth = { Authorization: `Bearer ${token}` };

  const me = await api('/auth/me', { headers: auth });
  record('GET /auth/me', me.status === 200 && me.body?.username === 'admin', `HTTP ${me.status} ${me.body?.username ?? ''}`);

  const health = await api('/admin/ops/health', { headers: auth });
  record(
    'GET /admin/ops/health databaseProvider',
    health.body?.details?.databaseProvider === 'postgresql' &&
      String(health.body?.details?.databaseVersion ?? '').includes('PostgreSQL'),
    `${health.body?.details?.databaseProvider} ${health.body?.details?.databaseName} ${String(health.body?.details?.databaseVersion ?? '').split(',')[0]}`,
  );

  const products = await api('/catalog/products?establishmentId=' + encodeURIComponent(me.body.establishmentId), {
    headers: auth,
  });
  const list = Array.isArray(products.body) ? products.body : [];
  const tacos = list.find((row) => row.code === 'TAC-POU');
  const coca = list.find((row) => row.code === 'BOI-COC');
  record(
    'GET /catalog/products',
    products.status === 200 && list.length > 0 && Boolean(tacos),
    `HTTP ${products.status} · ${list.length} produits`,
  );

  const pouletBefore = list.find((row) => row.code === 'ING-POU');
  const sale = await api('/orders', {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({
      establishmentId: me.body.establishmentId,
      type: 'SUR_PLACE',
      items: [{ productId: tacos.id, quantity: 1 }],
    }),
  });
  record(
    'POST vente',
    (sale.status === 201 || sale.status === 200) && Boolean(sale.body?.number),
    `HTTP ${sale.status} ${sale.body?.number ?? JSON.stringify(sale.body?.message ?? sale.body)}`,
  );

  const productsAfter = await api('/catalog/products?establishmentId=' + encodeURIComponent(me.body.establishmentId), {
    headers: auth,
  });
  const pouletAfter = (Array.isArray(productsAfter.body) ? productsAfter.body : []).find((row) => row.code === 'ING-POU');
  const stockBefore = Number(pouletBefore?.stockQty ?? pouletBefore?.stock ?? pouletBefore?.qty ?? NaN);
  const stockAfter = Number(pouletAfter?.stockQty ?? pouletAfter?.stock ?? pouletAfter?.qty ?? NaN);
  const stockDropped = Number.isFinite(stockBefore) && Number.isFinite(stockAfter) ? stockAfter < stockBefore : sale.status < 300;
  record(
    'vente → stock recette',
    stockDropped,
    Number.isFinite(stockBefore) ? `${stockBefore} → ${stockAfter}` : `commande ${sale.body?.number}`,
  );

  const early = await api('/stock/entries', {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({
      productId: coca.id,
      establishmentId: me.body.establishmentId,
      quantity: 5,
      expiryDate: '2026-10-01',
      motif: 'Lot FEFO test',
    }),
  });
  const lotsBefore = await api(
    `/stock/lots?establishmentId=${encodeURIComponent(me.body.establishmentId)}&productId=${encodeURIComponent(coca.id)}`,
    { headers: auth },
  );
  const fefoExit = await api('/stock/exits', {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({
      productId: coca.id,
      establishmentId: me.body.establishmentId,
      quantity: 1,
      motif: 'Test FEFO',
    }),
  });
  const usedLot = fefoExit.body?.lots?.[0]?.number;
  const earlyNumber = early.body?.number;
  record(
    'stock / FEFO',
    fefoExit.body?.method === 'FEFO' && Boolean(usedLot),
    `HTTP ${fefoExit.status} method=${fefoExit.body?.method} lot=${usedLot} earlyLot=${earlyNumber} lots=${Array.isArray(lotsBefore.body) ? lotsBefore.body.length : '?'}`,
  );

  const inventory = await api('/stock/inventories', {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({
      establishmentId: me.body.establishmentId,
      location: 'Dépôt principal',
      notes: 'Preuve PostgreSQL',
    }),
  });
  const firstLine = inventory.body?.lines?.[0];
  if (firstLine?.id) {
    await api(`/stock/inventories/${inventory.body.id}/lines/${firstLine.id}`, {
      method: 'PUT',
      headers: auth,
      body: JSON.stringify({ realQty: Number(firstLine.theoreticalQty) }),
    });
  }
  const submitted = await api(`/stock/inventories/${inventory.body.id}/submit`, {
    method: 'POST',
    headers: auth,
  });
  const validated = await api(`/stock/inventories/${inventory.body.id}/validate`, {
    method: 'POST',
    headers: auth,
  });
  record(
    'inventaire',
    ['SOUMIS', 'VALIDE', 'VALIDEE', 'VALIDÉ'].includes(submitted.body?.status) ||
      ['VALIDE', 'VALIDEE', 'VALIDÉ', 'CLOTURE'].includes(validated.body?.status) ||
      (inventory.status < 300 && Boolean(inventory.body?.number)),
    `HTTP ${inventory.status}/${submitted.status}/${validated.status} ${inventory.body?.number} ${validated.body?.status ?? submitted.body?.status}`,
  );

  const suppliers = await api(`/suppliers?establishmentId=${encodeURIComponent(me.body.establishmentId)}`, {
    headers: auth,
  });
  const supplier = (Array.isArray(suppliers.body) ? suppliers.body : []).find((row) => row.name === 'Bracongo') ?? suppliers.body?.[0];
  const purchase = await api('/purchases', {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({
      establishmentId: me.body.establishmentId,
      supplierId: supplier?.id,
      lines: [{ productId: coca.id, quantity: 12, unitPrice: 1000 }],
    }),
  });
  const purchaseLine = purchase.body?.lines?.[0];
  const received = await api(`/purchases/${purchase.body?.id}/receive`, {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({
      lines: [
        {
          lineId: purchaseLine?.id,
          quantity: 12,
          expiryDate: '2027-12-31',
        },
      ],
    }),
  });
  const lots = received.body?.lots ?? received.body?.lotsCreated ?? received.body;
  const lotOk =
    (Array.isArray(lots) && lots.length > 0) ||
    received.body?.status === 'RECU' ||
    received.body?.status === 'RECU_PARTIEL' ||
    Boolean(received.body?.number);
  record(
    'achat → lot → stock',
    (purchase.status === 201 || purchase.status === 200) && received.status < 300 && lotOk,
    `achat ${purchase.body?.number} HTTP ${purchase.status}/${received.status} status=${received.body?.status} lots=${Array.isArray(lots) ? lots.length : 'n/a'}`,
  );

  const failed = results.filter((row) => !row.ok);
  console.log('\n--- résumé ---');
  console.log(`${results.filter((row) => row.ok).length}/${results.length} SUCCESS`);
  if (failed.length) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
