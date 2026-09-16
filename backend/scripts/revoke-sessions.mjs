import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

const result = await prisma.refreshToken.updateMany({
  where: { revokedAt: null },
  data: { revokedAt: new Date() },
});

console.log(`SUCCESS  sessions refresh révoquées : ${result.count} (aucun token affiché)`);

await prisma.$disconnect();
