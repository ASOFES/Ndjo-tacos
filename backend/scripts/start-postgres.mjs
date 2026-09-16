import EmbeddedPostgres from 'embedded-postgres';
import { mkdirSync, existsSync } from 'fs';
import { join } from 'path';

const dataDir = join(process.cwd(), 'pgdata');
mkdirSync(dataDir, { recursive: true });
const initialized = existsSync(join(dataDir, 'PG_VERSION'));

const pg = new EmbeddedPostgres({
  databaseDir: dataDir,
  user: 'ndjo',
  password: 'ndjo',
  port: 5432,
  persistent: true,
  initdbFlags: ['--encoding=UTF8', '--locale=C'],
  postgresFlags: ['-c', 'listen_addresses=127.0.0.1'],
});

if (!initialized) {
  console.log('Initialisation du cluster PostgreSQL 16…');
  await pg.initialise();
}
console.log('Démarrage PostgreSQL sur 127.0.0.1:5432…');
await pg.start();
try {
  await pg.createDatabase('ndjo_tacos');
  console.log('Base ndjo_tacos créée.');
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  if (!/already exists/i.test(message)) {
    console.log(`createDatabase : ${message}`);
  }
}
console.log('PostgreSQL prêt. DATABASE_URL=postgresql://ndjo:ndjo@localhost:5432/ndjo_tacos?schema=public');
process.on('SIGINT', async () => {
  await pg.stop();
  process.exit(0);
});
