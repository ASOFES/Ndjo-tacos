import pg from 'pg';

const url = process.env.DATABASE_URL || 'postgresql://ndjo:ndjo@localhost:5432/ndjo_tacos';
const c = new pg.Client({ connectionString: url });
await c.connect();
const enc = await c.query('SHOW server_encoding');
const client = await c.query('SHOW client_encoding');
const tables = await c.query(
  "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1",
);
console.log('server_encoding=' + enc.rows[0].server_encoding);
console.log('client_encoding=' + client.rows[0].client_encoding);
console.log('tables=' + tables.rows.map((r) => r.tablename).join(',') || '(none)');
await c.end();
