/**
 * Test de concurrence FEFO :
 * Stock 10, deux sorties de 8 en parallèle.
 * Attendu : 1 succès, 1 refus, stock final = 2.
 */
import { PrismaClient } from '@prisma/client';
import { StockService } from '../src/stock/stock.service';

async function main() {
  const prisma = new PrismaClient();
  const stock = new StockService(prisma);
  const lot = await prisma.lot.findFirst({
    where: { qtyCurrent: { gte: 10 }, status: 'ACTIF' },
    include: { product: true },
  });
  if (!lot) {
    throw new Error('Aucun lot >= 10 pour le test');
  }
  const user = await prisma.user.findFirst({ where: { status: 'ACTIF' } });
  if (!user) throw new Error('Aucun utilisateur');
  await prisma.lot.update({ where: { id: lot.id }, data: { qtyCurrent: 10 } });
  const results = await Promise.allSettled([
    stock.consumeFefo({
      productId: lot.productId,
      establishmentId: lot.establishmentId,
      quantity: 8,
      userId: user.id,
      type: 'SORTIE',
      motif: 'Test concurrence A',
      destination: 'Test',
    }),
    stock.consumeFefo({
      productId: lot.productId,
      establishmentId: lot.establishmentId,
      quantity: 8,
      userId: user.id,
      type: 'SORTIE',
      motif: 'Test concurrence B',
      destination: 'Test',
    }),
  ]);
  const fresh = await prisma.lot.findUnique({ where: { id: lot.id } });
  console.log(
    JSON.stringify(
      {
        lot: lot.number,
        outcomes: results.map((row) =>
          row.status === 'fulfilled' ? 'SUCCESS' : 'REFUSED',
        ),
        finalQty: fresh?.qtyCurrent,
      },
      null,
      2,
    ),
  );
  await prisma.$disconnect();
}

main();
