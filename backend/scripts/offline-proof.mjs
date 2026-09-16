import { randomUUID } from 'crypto';

const API = 'http://localhost:3000';

async function api(path, { method = 'GET', token, body } = {}) {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let data;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  return { status: response.status, data };
}

function ok(name, pass, detail) {
  console.log(`${pass ? 'SUCCESS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
  if (!pass) process.exitCode = 1;
}

const login = await api('/auth/login', {
  method: 'POST',
  body: { username: 'admin', password: 'admin123' },
});
const token = login.data?.token;
const establishmentId = login.data?.user?.establishmentId;
ok('login sans afficher de token', Boolean(token) && login.status === 201, `HTTP ${login.status}`);

const products = await api(
  `/catalog/products?establishmentId=${encodeURIComponent(establishmentId)}&kind=VENTE`,
  { token },
);
const product = (products.data ?? []).find((row) => (row.stockQty ?? 0) > 0) ?? products.data?.[0];
ok('catalogue vente', Boolean(product?.id), product?.name);

const clientUuid = randomUUID();
const orderOp = {
  clientUuid,
  type: 'ORDER',
  payload: {
    establishmentId,
    clientUuid,
    type: 'SUR_PLACE',
    method: 'ESPECES',
    received: 15000,
    items: [{ productId: product.id, quantity: 1 }],
  },
};

const first = await api('/sync/push', {
  method: 'POST',
  token,
  body: { operations: [orderOp] },
});
const firstStatus = first.data?.results?.[0]?.status;
const firstNumber = first.data?.results?.[0]?.number;
ok(
  'push ORDER #1 APPLIQUE',
  first.status < 400 && firstStatus === 'APPLIQUE' && Boolean(firstNumber),
  `${firstStatus} ${firstNumber ?? ''}`.trim(),
);

const second = await api('/sync/push', {
  method: 'POST',
  token,
  body: { operations: [orderOp] },
});
const secondStatus = second.data?.results?.[0]?.status;
ok(
  'push ORDER #2 même clientUuid → DEJA_APPLIQUE',
  secondStatus === 'DEJA_APPLIQUE',
  secondStatus,
);

const listed = await api(`/orders?establishmentId=${encodeURIComponent(establishmentId)}`, { token });
const same = (listed.data ?? []).filter((row) => row.clientUuid === clientUuid);
ok('une seule vente PostgreSQL pour ce clientUuid', same.length === 1, `count=${same.length}`);

const stockProduct = (products.data ?? []).find((row) => row.kind !== 'VENTE' && (row.stockQty ?? 0) > 0)
  ?? (await api(`/catalog/products?establishmentId=${encodeURIComponent(establishmentId)}`, { token })).data?.find(
    (row) => (row.stockQty ?? 0) > 0,
  )
  ?? product;

const exitUuid = randomUUID();
const exitOp = {
  clientUuid: exitUuid,
  type: 'STOCK_EXIT',
  payload: {
    establishmentId,
    productId: stockProduct.id,
    quantity: 1,
    type: 'SORTIE',
    motif: 'preuve offline',
    destination: 'Cuisine',
  },
};
const exit1 = await api('/sync/push', { method: 'POST', token, body: { operations: [exitOp] } });
const exit2 = await api('/sync/push', { method: 'POST', token, body: { operations: [exitOp] } });
ok(
  'STOCK_EXIT replay → DEJA_APPLIQUE (pas de double sortie)',
  exit1.data?.results?.[0]?.status === 'APPLIQUE' && exit2.data?.results?.[0]?.status === 'DEJA_APPLIQUE',
  `${exit1.data?.results?.[0]?.status} puis ${exit2.data?.results?.[0]?.status}`,
);

const refuseUuid = randomUUID();
const refuse = await api('/sync/push', {
  method: 'POST',
  token,
  body: {
    operations: [
      {
        clientUuid: refuseUuid,
        type: 'STOCK_EXIT',
        payload: {
          establishmentId,
          productId: stockProduct.id,
          quantity: 999999,
          type: 'SORTIE',
          motif: 'preuve refus',
          destination: 'Cuisine',
        },
      },
    ],
  },
});
ok(
  'STOCK_EXIT stock insuffisant → REFUSE (pas de qty négative)',
  refuse.data?.results?.[0]?.status === 'REFUSE',
  refuse.data?.results?.[0]?.error,
);

const summary = await api(`/stock/summary?establishmentId=${encodeURIComponent(establishmentId)}`, { token });
const ingredient = (summary.data ?? []).find((row) => Number(row.stockQty) >= 2) ?? stockProduct;
const remaining = Number(ingredient.stockQty ?? 0);
const concurrentQty = remaining > 0 ? remaining : 1;
const a = randomUUID();
const b = randomUUID();
const concurrentPayload = {
  establishmentId,
  productId: ingredient.id,
  quantity: concurrentQty,
  type: 'SORTIE',
  motif: 'concurrent',
  destination: 'Cuisine',
};
const [left, right] = await Promise.all([
  api('/sync/push', {
    method: 'POST',
    token,
    body: { operations: [{ clientUuid: a, type: 'STOCK_EXIT', payload: concurrentPayload }] },
  }),
  api('/sync/push', {
    method: 'POST',
    token,
    body: { operations: [{ clientUuid: b, type: 'STOCK_EXIT', payload: concurrentPayload }] },
  }),
]);
const statuses = [left.data?.results?.[0]?.status, right.data?.results?.[0]?.status];
ok(
  '2 appareils / même lots : une APPLIQUE et une REFUSE',
  statuses.includes('APPLIQUE') && statuses.includes('REFUSE'),
  `${statuses.join(' + ')} qty=${concurrentQty} ${ingredient.name ?? ''}`,
);

console.log('NOTE  tokens jamais affichés. Mot de passe admin123 à changer hors développement.');
