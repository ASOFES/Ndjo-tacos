const { existsSync } = require('fs');
const { spawn, spawnSync } = require('child_process');

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL manquant. Dans Railway : + Add → Database → PostgreSQL, puis relancez le déploiement.');
  process.exit(1);
}

const migrate = spawnSync('npx prisma migrate deploy', { stdio: 'inherit', shell: true });
if (migrate.status !== 0) {
  process.exit(migrate.status || 1);
}

const entry = existsSync('dist/src/main.js') ? 'dist/src/main.js' : 'dist/main.js';
if (!existsSync(entry)) {
  console.error('Build introuvable (dist/main.js).');
  process.exit(1);
}

const child = spawn(process.execPath, [entry], { stdio: 'inherit' });
child.on('exit', (code) => process.exit(code ?? 1));
