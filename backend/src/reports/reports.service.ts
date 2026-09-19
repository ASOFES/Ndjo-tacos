import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';

function startOfDay(date: Date) {
  const next = new Date(date);
  next.setHours(0, 0, 0, 0);
  return next;
}

function endOfDay(date: Date) {
  const next = new Date(date);
  next.setHours(23, 59, 59, 999);
  return next;
}

function dayKey(date: Date) {
  return date.toISOString().slice(0, 10);
}

function add(map: Map<string, number>, key: string, value: number) {
  map.set(key, (map.get(key) ?? 0) + value);
}

@Injectable()
export class ReportsService {
  constructor(private readonly prisma: PrismaService) {}

  range(period?: string, from?: string, to?: string) {
    const now = new Date();
    if (from || to) {
      return {
        from: from ? startOfDay(new Date(from)) : startOfDay(now),
        to: to ? endOfDay(new Date(to)) : endOfDay(now),
        period: 'PERSONNALISE',
      };
    }
    if (period === 'semaine') {
      const fromDate = startOfDay(now);
      fromDate.setDate(fromDate.getDate() - 6);
      return { from: fromDate, to: endOfDay(now), period: 'SEMAINE' };
    }
    if (period === 'mois') {
      return {
        from: new Date(now.getFullYear(), now.getMonth(), 1),
        to: endOfDay(now),
        period: 'MOIS',
      };
    }
    return { from: startOfDay(now), to: endOfDay(now), period: 'JOUR' };
  }

  async dashboard(establishmentId?: string) {
    const report = await this.build({ establishmentId, period: 'jour' });
    const extras = await this.opsCounts(establishmentId);
    const transfers = report.stock.transfers;
    return {
      products: extras.products,
      publications: extras.publications,
      versions: extras.versions,
      pending: extras.pending,
      kitchen: extras.kitchen,
      ordersToday: report.sales.orders,
      salesToday: report.finance.revenue,
      stockValue: report.stock.value,
      deliveries: report.delivery.count,
      rupture: report.stock.rupture,
      expiring: report.stock.expiring,
      paymentsCash: report.finance.payments.ESPECES,
      paymentsMm: report.finance.payments.MOBILE_MONEY,
      paymentsCard: report.finance.payments.CARTE,
      paymentsTransfer: report.finance.payments.VIREMENT,
      materialCostToday: report.finance.materialCost,
      productExpenseToday: report.finance.productExpense,
      marginToday: report.finance.margin,
      profitToday: report.finance.profit,
      kitchenExtraCostToday: report.stock.kitchenExtraCost,
      transfersCountToday: transfers.count,
      transfersOutToday: transfers.outCount,
      transfersInToday: transfers.inCount,
      transferValueOutToday: transfers.valueOut,
      transferValueInToday: transfers.valueIn,
      transfersPendingReceive: transfers.pendingReceive,
    };
  }

  async build(params: {
    establishmentId?: string;
    period?: string;
    from?: string;
    to?: string;
  }) {
    const { from, to, period } = this.range(params.period, params.from, params.to);
    const whereEst = params.establishmentId ? { establishmentId: params.establishmentId } : {};
    const whereDate = { createdAt: { gte: from, lte: to } };

    const transferEstFilter = params.establishmentId
      ? { OR: [{ sourceId: params.establishmentId }, { destId: params.establishmentId }] }
      : {};

    const [orders, lots, movements, kitchenMoves, transferMoves, transfersRaw, losses, inventories, recipes] =
      await Promise.all([
      this.prisma.order.findMany({
        where: { ...whereEst, ...whereDate },
        include: {
          items: { include: { product: { include: { category: true } } } },
          payments: true,
          user: { select: { id: true, name: true } },
          driver: { select: { id: true, name: true } },
          establishment: { select: { id: true, code: true, name: true } },
        },
        orderBy: { createdAt: 'asc' },
      }),
      this.prisma.lot.findMany({
        where: params.establishmentId ? { establishmentId: params.establishmentId } : undefined,
        include: { product: true },
      }),
      this.prisma.stockMovement.findMany({
        where: { ...whereEst, ...whereDate },
        include: {
          product: { select: { name: true, unit: true } },
          lot: true,
          user: { select: { name: true } },
        },
        orderBy: { createdAt: 'desc' },
        take: 80,
      }),
      this.prisma.stockMovement.findMany({
        where: {
          ...whereEst,
          ...whereDate,
          OR: [
            { type: { in: ['CONSOMMATION', 'VENTE'] } },
            { type: 'SORTIE', destination: 'Cuisine' },
            { motif: { startsWith: 'CUI' } },
          ],
        },
        include: {
          product: { select: { name: true, unit: true } },
          lot: { select: { number: true, priceBuy: true, entryDate: true } },
        },
        orderBy: { createdAt: 'desc' },
      }),
      this.prisma.stockMovement.findMany({
        where: {
          ...whereEst,
          ...whereDate,
          OR: [
            { type: 'TRANSFERT' },
            { type: 'ENTREE', motif: { startsWith: 'Réception transfert' } },
          ],
        },
        include: {
          product: { select: { name: true, unit: true } },
          lot: { select: { number: true, priceBuy: true } },
        },
        orderBy: { createdAt: 'desc' },
      }),
      this.prisma.transfer.findMany({
        where: {
          ...transferEstFilter,
          OR: [
            { createdAt: { gte: from, lte: to } },
            { shippedAt: { gte: from, lte: to } },
            { receivedAt: { gte: from, lte: to } },
          ],
        },
        include: {
          source: { select: { id: true, name: true, code: true } },
          dest: { select: { id: true, name: true, code: true } },
          product: { select: { id: true, name: true, unit: true } },
        },
        orderBy: { createdAt: 'desc' },
      }),
      this.prisma.stockLoss.findMany({
        where: { ...whereEst, declaredAt: { gte: from, lte: to } },
        include: {
          product: { select: { name: true, unit: true } },
          lot: { select: { number: true, priceBuy: true } },
          declaredBy: { select: { name: true } },
          validatedBy: { select: { name: true } },
        },
        orderBy: { declaredAt: 'desc' },
      }),
      this.prisma.inventorySession.findMany({
        where: { ...whereEst, createdAt: { gte: from, lte: to } },
        include: {
          countedBy: { select: { name: true } },
          validatedBy: { select: { name: true } },
          _count: { select: { lines: true } },
        },
        orderBy: { createdAt: 'desc' },
      }),
      this.prisma.recipe.findMany({
        include: { items: { include: { ingredient: true } } },
      }),
    ]);

    const recipeCost = new Map<string, number>();
    for (const recipe of recipes) {
      const cost = recipe.items.reduce(
        (sum, item) => sum + (item.ingredient.priceBuy ?? 0) * item.quantity,
        0,
      );
      recipeCost.set(recipe.productId, Math.round(cost));
    }

    const lotCostBySale = new Map<string, number>();
    const kitchenExits = kitchenMoves.map((move) => {
      const qty = Math.abs(Number(move.quantity));
      const priceBuy = move.lot?.priceBuy ?? 0;
      const cmd = /^CMD:([^:]+):/.exec(move.motif ?? '');
      return {
        type: move.type,
        product: move.product.name,
        unit: move.product.unit,
        lot: move.lot?.number ?? '—',
        entryDate: move.lot?.entryDate?.toISOString() ?? null,
        quantity: qty,
        priceBuy,
        cost: Math.round(qty * priceBuy),
        orderNumber: cmd?.[1] ?? null,
        createdAt: move.createdAt.toISOString(),
      };
    });
    const kitchenCost = kitchenExits.reduce((sum, row) => sum + row.cost, 0);
    const kitchenExtraCost = kitchenExits
      .filter((row) => row.type === 'SORTIE')
      .reduce((sum, row) => sum + row.cost, 0);

    const costByTransferNumber = new Map<string, { out: number; in: number; lot?: string }>();
    for (const move of transferMoves) {
      const match = /transfert\s+(\S+)/i.exec(move.motif ?? '');
      if (!match) continue;
      const number = match[1];
      const cost = Math.round(Math.abs(Number(move.quantity)) * (move.lot?.priceBuy ?? 0));
      const row = costByTransferNumber.get(number) ?? { out: 0, in: 0, lot: move.lot?.number };
      if (move.type === 'TRANSFERT') row.out += cost;
      else row.in += cost;
      if (move.lot?.number) row.lot = move.lot.number;
      costByTransferNumber.set(number, row);
    }

    const transferLines = transfersRaw.map((row) => {
      const costs = costByTransferNumber.get(row.number);
      const direction =
        params.establishmentId && row.destId === params.establishmentId
          ? 'IN'
          : params.establishmentId && row.sourceId === params.establishmentId
            ? 'OUT'
            : 'BOTH';
      return {
        number: row.number,
        status: row.status,
        product: row.product.name,
        unit: row.product.unit,
        quantity: row.quantity,
        source: row.source.name,
        dest: row.dest.name,
        lot: costs?.lot ?? null,
        costOut: costs?.out ?? 0,
        costIn: costs?.in ?? 0,
        cost: direction === 'IN' ? costs?.in ?? 0 : costs?.out ?? costs?.in ?? 0,
        direction,
        shippedAt: row.shippedAt?.toISOString() ?? null,
        receivedAt: row.receivedAt?.toISOString() ?? null,
        createdAt: row.createdAt.toISOString(),
      };
    });

    const valueOut = transferMoves
      .filter((row) => row.type === 'TRANSFERT')
      .reduce((sum, row) => sum + Math.abs(Number(row.quantity)) * (row.lot?.priceBuy ?? 0), 0);
    const valueIn = transferMoves
      .filter((row) => row.type === 'ENTREE')
      .reduce((sum, row) => sum + Math.abs(Number(row.quantity)) * (row.lot?.priceBuy ?? 0), 0);
    const outCount = transferLines.filter(
      (row) =>
        row.status !== 'ANNULE' &&
        (!params.establishmentId || row.direction === 'OUT' || row.direction === 'BOTH'),
    ).length;
    const inCount = transferLines.filter(
      (row) =>
        row.status !== 'ANNULE' &&
        (!params.establishmentId || row.direction === 'IN' || row.direction === 'BOTH'),
    ).length;
    const quantity = transferLines
      .filter((row) => row.status !== 'ANNULE')
      .reduce((sum, row) => sum + Number(row.quantity), 0);

    const byDayTransfers = new Map<string, { date: string; count: number; quantity: number; valueOut: number }>();
    for (const row of transferLines) {
      if (row.status === 'ANNULE') continue;
      const date = (row.shippedAt ?? row.createdAt).slice(0, 10);
      const dayRow = byDayTransfers.get(date) ?? { date, count: 0, quantity: 0, valueOut: 0 };
      dayRow.count += 1;
      dayRow.quantity += Number(row.quantity);
      dayRow.valueOut += row.costOut || row.cost;
      byDayTransfers.set(date, dayRow);
    }

    const bySiteTransfers = new Map<
      string,
      { name: string; outCount: number; outQty: number; outValue: number; inCount: number; inQty: number; inValue: number }
    >();
    for (const row of transferLines) {
      if (row.status === 'ANNULE') continue;
      const key = `${row.source} → ${row.dest}`;
      const site = bySiteTransfers.get(key) ?? {
        name: key,
        outCount: 0,
        outQty: 0,
        outValue: 0,
        inCount: 0,
        inQty: 0,
        inValue: 0,
      };
      site.outCount += 1;
      site.outQty += Number(row.quantity);
      site.outValue += row.costOut;
      site.inCount += row.status === 'RECU' ? 1 : 0;
      site.inQty += row.status === 'RECU' ? Number(row.quantity) : 0;
      site.inValue += row.costIn;
      bySiteTransfers.set(key, site);
    }

    const pendingReceive = await this.prisma.transfer.count({
      where: {
        status: 'EN_TRANSIT',
        ...(params.establishmentId ? { destId: params.establishmentId } : {}),
      },
    });

    const transfers = {
      count: transferLines.filter((row) => row.status !== 'ANNULE').length,
      quantity: Math.round(quantity * 1000) / 1000,
      valueOut: Math.round(valueOut),
      valueIn: Math.round(valueIn),
      outCount,
      inCount,
      pendingReceive,
      byDay: [...byDayTransfers.values()].sort((a, b) => a.date.localeCompare(b.date)),
      bySite: [...bySiteTransfers.values()].sort((a, b) => b.outValue - a.outValue),
      lines: transferLines,
      movements: transferMoves.map((row) => ({
        number: row.number,
        type: row.type,
        quantity: row.quantity,
        motif: row.motif,
        product: row.product.name,
        unit: row.product.unit,
        lot: row.lot?.number,
        priceBuy: row.lot?.priceBuy,
        cost: Math.round(Math.abs(Number(row.quantity)) * (row.lot?.priceBuy ?? 0)),
        createdAt: row.createdAt.toISOString(),
      })),
    };

    for (const move of kitchenMoves) {
      const match = /^CMD:([^:]+):([^:\s]+)/.exec(move.motif ?? '');
      if (!match) continue;
      const key = `${match[1]}|${match[2]}`;
      const cost = Math.round(Math.abs(Number(move.quantity)) * (move.lot?.priceBuy ?? 0));
      lotCostBySale.set(key, (lotCostBySale.get(key) ?? 0) + cost);
    }

    const paid = orders.filter((order) => order.paymentStatus === 'PAYE');
    const sold = orders.filter((order) => order.status !== 'ANNULEE');
    const byDay = new Map<string, number>();
    const byProduct = new Map<string, { name: string; qty: number; revenue: number; cost: number }>();
    const byCategory = new Map<string, { name: string; revenue: number; cost: number }>();
    const byCashier = new Map<string, { name: string; orders: number; revenue: number }>();
    const byEstablishment = new Map<string, { name: string; orders: number; revenue: number }>();
    const payments = { ESPECES: 0, MOBILE_MONEY: 0, CARTE: 0, VIREMENT: 0 };
    let materialCost = 0;

    for (const order of sold) {
      add(byDay, dayKey(order.createdAt), order.total);
      const cashier = byCashier.get(order.userId) ?? {
        name: order.user?.name ?? '—',
        orders: 0,
        revenue: 0,
      };
      cashier.orders += 1;
      cashier.revenue += order.total;
      byCashier.set(order.userId, cashier);

      const place = byEstablishment.get(order.establishmentId) ?? {
        name: order.establishment?.name ?? order.establishmentId,
        orders: 0,
        revenue: 0,
      };
      place.orders += 1;
      place.revenue += order.total;
      byEstablishment.set(order.establishmentId, place);

      const soldByProduct = new Map<string, { name: string; qty: number; revenue: number }>();
      for (const item of order.items) {
        const row = soldByProduct.get(item.productId) ?? {
          name: item.name,
          qty: 0,
          revenue: 0,
        };
        row.qty += item.quantity;
        row.revenue += item.lineTotal;
        soldByProduct.set(item.productId, row);
      }

      for (const item of order.items) {
        const categoryName = item.product.category?.name ?? 'Sans catégorie';
        const category = byCategory.get(categoryName) ?? { name: categoryName, revenue: 0, cost: 0 };
        category.revenue += item.lineTotal;
        byCategory.set(categoryName, category);
      }

      for (const [productId, soldRow] of soldByProduct) {
        const catalogUnit = recipeCost.get(productId) ?? 0;
        const fallback = catalogUnit > 0
          ? catalogUnit * soldRow.qty
          : (order.items.find((row) => row.productId === productId)?.product.priceBuy ?? 0) * soldRow.qty;
        const cost = lotCostBySale.get(`${order.number}|${productId}`) ?? fallback;
        materialCost += cost;
        const product = byProduct.get(productId) ?? {
          name: soldRow.name,
          qty: 0,
          revenue: 0,
          cost: 0,
        };
        product.qty += soldRow.qty;
        product.revenue += soldRow.revenue;
        product.cost += cost;
        byProduct.set(productId, product);

        const sample = order.items.find((row) => row.productId === productId);
        const categoryName = sample?.product.category?.name ?? 'Sans catégorie';
        const category = byCategory.get(categoryName) ?? { name: categoryName, revenue: 0, cost: 0 };
        category.cost += cost;
        byCategory.set(categoryName, category);
      }
    }

    for (const order of paid) {
      for (const payment of order.payments.filter((row) => row.status === 'CONFIRME' || row.status === 'PAYE')) {
        const method = payment.method === 'CASH' ? 'ESPECES' : payment.method;
        if (method in payments) payments[method as keyof typeof payments] += payment.amount;
      }
    }

    const stockByProduct = new Map<string, { name: string; qty: number; alert: number; unit: string }>();
    let stockValue = 0;
    let expiring = 0;
    for (const lot of lots) {
      stockValue += lot.qtyCurrent * lot.priceBuy;
      if (lot.expiryDate && lot.qtyCurrent > 0) {
        const days = (lot.expiryDate.getTime() - Date.now()) / 86400000;
        if (days <= 7) expiring += 1;
      }
      const row = stockByProduct.get(lot.productId) ?? {
        name: lot.product.name,
        qty: 0,
        alert: lot.product.stockAlert,
        unit: lot.product.unit,
      };
      row.qty += lot.qtyCurrent;
      stockByProduct.set(lot.productId, row);
    }
    const rupture = [...stockByProduct.values()].filter((row) => row.qty <= 0).length;
    const low = [...stockByProduct.values()].filter((row) => row.qty > 0 && row.qty <= row.alert);

    const purchases = movements
      .filter((row) => row.type === 'ENTREE')
      .reduce((sum, row) => sum + row.quantity * (row.lot?.priceBuy ?? 0), 0);
    const lossValue = losses
      .filter((row) => row.status === 'VALIDEE')
      .reduce((sum, row) => sum + row.quantity * (row.lot?.priceBuy ?? 0), 0);

    const deliveries = orders.filter((order) => order.type === 'LIVRAISON');
    const delivered = deliveries.filter((order) => order.status === 'LIVREE');
    const byDriver = new Map<string, { name: string; count: number }>();
    for (const order of deliveries) {
      const key = order.driverId ?? 'NON_AFFECTE';
      const row = byDriver.get(key) ?? { name: order.driver?.name ?? 'Non affecté', count: 0 };
      row.count += 1;
      byDriver.set(key, row);
    }
    const durations = delivered.map(
      (order) => (order.updatedAt.getTime() - order.createdAt.getTime()) / 60000,
    );
    const avgMinutes = durations.length
      ? Math.round(durations.reduce((sum, value) => sum + value, 0) / durations.length)
      : null;

    const revenue = sold.reduce((sum, order) => sum + order.total, 0);
    const paidRevenue = paid.reduce((sum, order) => sum + order.total, 0);
    const grossRevenue = sold.reduce(
      (sum, order) => sum + (order.subtotal || order.total - order.deliveryFee) + order.deliveryFee,
      0,
    );
    const discounts = sold.reduce((sum, order) => sum + (order.discountAmount || 0), 0);
    const discountsByMotif = new Map<string, { motif: string; count: number; amount: number }>();
    for (const order of sold) {
      if (!order.discountAmount) continue;
      const motif = order.discountMotif || 'AUTRE';
      const row = discountsByMotif.get(motif) ?? { motif, count: 0, amount: 0 };
      row.count += 1;
      row.amount += order.discountAmount;
      discountsByMotif.set(motif, row);
    }
    const productExpense = Math.round(materialCost);
    const roundedLoss = Math.round(lossValue);
    const margin = Math.round(revenue - productExpense);
    const profit = Math.round(revenue - productExpense - roundedLoss);

    return {
      period,
      from: from.toISOString(),
      to: to.toISOString(),
      sales: {
        orders: orders.length,
        paid: paid.length,
        sold: sold.length,
        revenue,
        grossRevenue,
        discounts,
        discountsByMotif: [...discountsByMotif.values()].sort((a, b) => b.amount - a.amount),
        paidRevenue,
        productExpense,
        profit,
        byDay: [...byDay.entries()].map(([date, total]) => ({ date, total })),
        byProduct: [...byProduct.values()]
          .map((row) => ({
            ...row,
            cost: Math.round(row.cost),
            expense: Math.round(row.cost),
            margin: Math.round(row.revenue - row.cost),
            profit: Math.round(row.revenue - row.cost),
          }))
          .sort((a, b) => b.revenue - a.revenue),
        byCategory: [...byCategory.values()]
          .map((row) => ({
            ...row,
            cost: Math.round(row.cost),
            expense: Math.round(row.cost),
            profit: Math.round(row.revenue - row.cost),
          }))
          .sort((a, b) => b.revenue - a.revenue),
        byCashier: [...byCashier.values()].sort((a, b) => b.revenue - a.revenue),
        byEstablishment: [...byEstablishment.values()].sort((a, b) => b.revenue - a.revenue),
      },
      stock: {
        value: Math.round(stockValue),
        rupture,
        expiring,
        low: low.map((row) => ({ name: row.name, qty: row.qty, unit: row.unit, alert: row.alert })),
        movements: movements.map((row) => ({
          number: row.number,
          type: row.type,
          quantity: row.quantity,
          motif: row.motif,
          product: row.product.name,
          lot: row.lot?.number,
          priceBuy: row.lot?.priceBuy,
          user: row.user.name,
          createdAt: row.createdAt,
        })),
        kitchenExits,
        kitchenCost,
        kitchenExtraCost,
        transfers,
        losses: losses.map((row) => ({
          number: row.number,
          product: row.product.name,
          lot: row.lot.number,
          quantity: row.quantity,
          unit: row.unit,
          motif: row.motif,
          status: row.status,
          declaredBy: row.declaredBy.name,
          validatedBy: row.validatedBy?.name,
        })),
        inventories: inventories.map((row) => ({
          number: row.number,
          status: row.status,
          location: row.location,
          lines: row._count.lines,
          countedBy: row.countedBy.name,
          validatedBy: row.validatedBy?.name,
        })),
      },
      delivery: {
        count: deliveries.length,
        delivered: delivered.length,
        cancelled: orders.filter((order) => order.status === 'ANNULEE').length,
        cashOnDelivery: deliveries.filter((order) => order.paymentStatus === 'EN_ATTENTE').length,
        avgMinutes,
        avgNote: 'Estimé entre création et passage au statut LIVREE (heures départ/arrivée pas encore enregistrées).',
        byDriver: [...byDriver.values()].sort((a, b) => b.count - a.count),
      },
      finance: {
        revenue,
        grossRevenue,
        discounts,
        discountsByMotif: [...discountsByMotif.values()].sort((a, b) => b.amount - a.amount),
        paidRevenue,
        purchases: Math.round(purchases),
        productExpense,
        expenses: 0,
        kitchenExtraCost,
        expensesNote:
          'CA net = après remises. CA brut et remises sont séparés pour la transparence. Dépense produits = lots FEFO des ventes. Transferts et sorties magasin→cuisine = journal stock (hors bénéfice).',
        materialCost: productExpense,
        lossValue: roundedLoss,
        margin,
        profit,
        result: [
          { label: 'CA brut (avant remise)', amount: grossRevenue },
          { label: 'Remises accordées', amount: -discounts },
          { label: 'Chiffre d’affaires net', amount: revenue },
          { label: 'Dépense produits vendus', amount: -productExpense },
          { label: 'Pertes valorisées', amount: -roundedLoss },
          { label: 'Total bénéfice', amount: profit },
        ],
        payments,
      },
    };
  }

  private async opsCounts(establishmentId?: string) {
    const whereEst = establishmentId ? { establishmentId } : {};
    const [products, publications, versions, pending, kitchen] = await Promise.all([
      this.prisma.product.count({ where: whereEst }),
      this.prisma.publication.count({ where: { ...whereEst, status: 'PUBLIEE' } }),
      this.prisma.appVersion.count({ where: { status: 'PUBLIEE' } }),
      this.prisma.deviceDeployment.count({ where: { ...whereEst, status: 'EN_ATTENTE' } }),
      this.prisma.order.count({
        where: { ...whereEst, status: { in: ['NOUVELLE', 'EN_PREPARATION'] } },
      }),
    ]);
    return { products, publications, versions, pending, kitchen };
  }
}
