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

const adminLogin = await api('/auth/login', {
  method: 'POST',
  body: { username: 'admin', password: 'admin123' },
});
const adminToken = adminLogin.data?.token;
ok('login admin', Boolean(adminToken), `HTTP ${adminLogin.status}`);

const me = await api('/auth/me', { token: adminToken });
ok(
  'GET /auth/me permissions DB',
  me.data?.permissions?.includes('*'),
  JSON.stringify(me.data?.permissions),
);

const matrix = await api('/permissions', { token: adminToken });
const roles = matrix.data?.roles ?? [];
const cashier = roles.find((row) => row.role === 'CAISSIER');
ok(
  'GET /permissions source=database',
  matrix.data?.source === 'database' && (matrix.data?.permissions?.length ?? 0) > 10,
  `source=${matrix.data?.source} perms=${matrix.data?.permissions?.length} roles=${roles.length}`,
);

const cashierLogin = await api('/auth/login', {
  method: 'POST',
  body: { username: 'caissier', password: 'admin123' },
});
const cashierToken = cashierLogin.data?.token;
const products = await api(
  `/catalog/products?establishmentId=${encodeURIComponent(cashierLogin.data?.user?.establishmentId)}`,
  { token: cashierToken },
);
ok('caissier catalogue.voir', products.status === 200, `HTTP ${products.status}`);

const entry = await api('/stock/entries', {
  method: 'POST',
  token: cashierToken,
  body: {
    productId: products.data?.[0]?.id,
    establishmentId: cashierLogin.data?.user?.establishmentId,
    quantity: 1,
  },
});
ok(
  'caissier stock.entree refuse',
  entry.status === 403,
  `HTTP ${entry.status} ${JSON.stringify(entry.data?.message ?? entry.data)}`,
);

const saved = await api('/roles/CAISSIER/permissions', {
  method: 'PUT',
  token: adminToken,
  body: { keys: [...(cashier?.keys ?? []), 'stock.entree'] },
});
ok('PUT RolePermission CAISSIER +stock.entree', saved.status < 300, `HTTP ${saved.status}`);

const entry2 = await api('/stock/entries', {
  method: 'POST',
  token: cashierToken,
  body: {
    productId: products.data?.[0]?.id,
    establishmentId: cashierLogin.data?.user?.establishmentId,
    quantity: 1,
  },
});
ok(
  'caissier stock.entree apres DB',
  entry2.status !== 403,
  `HTTP ${entry2.status} ${JSON.stringify(entry2.data?.message ?? entry2.data?.number ?? '')}`,
);

const restored = await api('/roles/CAISSIER/permissions', {
  method: 'PUT',
  token: adminToken,
  body: { keys: cashier?.keys ?? [] },
});
ok('restore CAISSIER matrix', restored.status < 300, `HTTP ${restored.status}`);

const denySuper = await api('/roles/SUPER_ADMIN/permissions', {
  method: 'PUT',
  token: adminToken,
  body: { keys: ['catalogue.voir'] },
});
ok('SUPER_ADMIN locked', denySuper.status >= 400, `HTTP ${denySuper.status}`);
