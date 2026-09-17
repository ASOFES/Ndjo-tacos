const { existsSync } = require('fs');
const { spawn, spawnSync } = require('child_process');
const { PrismaClient } = require('@prisma/client');

if (!process.env.DATABASE_URL) {
  console.error('DATABASE_URL manquant. Dans Railway : + Add → Database → PostgreSQL, puis relancez le déploiement.');
  process.exit(1);
}

const migrate = spawnSync('npx prisma migrate deploy', { stdio: 'inherit', shell: true });
if (migrate.status !== 0) {
  process.exit(migrate.status || 1);
}

function startApp() {
  const entry = existsSync('dist/src/main.js') ? 'dist/src/main.js' : 'dist/main.js';
  if (!existsSync(entry)) {
    console.error('Build introuvable (dist/main.js).');
    process.exit(1);
  }
  const child = spawn(process.execPath, [entry], { stdio: 'inherit' });
  child.on('exit', (code) => process.exit(code ?? 1));
}

async function seedIfEmpty() {
  const prisma = new PrismaClient();
  try {
    const count = await prisma.user.count();
    if (count > 0) {
      console.log(`Base déjà initialisée (${count} utilisateur(s)).`);
      return;
    }
  } finally {
    await prisma.$disconnect();
  }
  const seedEntry = existsSync('dist/prisma/seed.js') ? 'dist/prisma/seed.js' : null;
  if (!seedEntry) {
    console.error('Seed introuvable (dist/prisma/seed.js).');
    process.exit(1);
  }
  console.log('Base vide : seed officiel NDJO TACOS…');
  const seed = spawnSync(process.execPath, [seedEntry], { stdio: 'inherit' });
  if (seed.status !== 0) {
    process.exit(seed.status || 1);
  }
}

seedIfEmpty().then(startApp).catch((err) => {
  console.error(err);
  process.exit(1);
});
