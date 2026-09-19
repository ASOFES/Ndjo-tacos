import { BadRequestException, Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { ReportsService } from '../reports/reports.service';
import { ExcelSheet, buildExcel } from './excel';
import { PdfDocument, PdfTable, buildPremiumPdf, fcPdf } from './pdf';

export type ExportKind = 'stock' | 'catalog' | 'sales' | 'reports';
export type ExportFormat = 'xls' | 'pdf';

function stamp() {
  return new Date().toISOString().slice(0, 10);
}

function day(value?: Date | string | null) {
  if (!value) return '';
  return String(value).slice(0, 10);
}

@Injectable()
export class ExportService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly reports: ReportsService,
  ) {}

  async file(kind: ExportKind, format: ExportFormat, params: {
    establishmentId?: string;
    period?: string;
    from?: string;
    to?: string;
  }) {
    const place = params.establishmentId
      ? await this.prisma.establishment.findUnique({ where: { id: params.establishmentId } })
      : null;
    const site = place?.name ?? 'Tous les etablissements';
    const built = await this.build(kind, { ...params, site });
    const date = stamp();
    if (format === 'xls') {
      return {
        buffer: buildExcel(built.sheets),
        mime: 'application/vnd.ms-excel',
        filename: `NDJO-${kind}-${date}.xls`,
      };
    }
    if (format === 'pdf') {
      return {
        buffer: buildPremiumPdf(built.doc),
        mime: 'application/pdf',
        filename: `NDJO-${kind}-${date}.pdf`,
      };
    }
    throw new BadRequestException('Format invalide');
  }

  private async build(
    kind: ExportKind,
    params: { establishmentId?: string; period?: string; from?: string; to?: string; site: string },
  ) {
    if (kind === 'stock') return this.stock(params);
    if (kind === 'catalog') return this.catalog(params);
    if (kind === 'sales') return this.sales(params);
    if (kind === 'reports') return this.report(params);
    throw new BadRequestException('Extraction inconnue');
  }

  private doc(
    title: string,
    site: string,
    tables: PdfTable[],
    extra?: Partial<PdfDocument>,
  ): PdfDocument {
    return { title, site, tables, ...extra };
  }

  private moneyTable(
    title: string,
    headers: string[],
    rows: unknown[][],
    totals?: unknown[],
    rightFrom = 1,
  ): PdfTable {
    const widths = headers.map((header, index) => {
      if (index === 0) return 180;
      return Math.max(70, Math.floor((523 - 180) / Math.max(1, headers.length - 1)));
    });
    return {
      title,
      columns: headers.map((header, index) => ({
        header,
        width: widths[index],
        align: index >= rightFrom ? 'right' : 'left',
      })),
      rows,
      totals,
    };
  }

  private async stock(params: { establishmentId?: string; site: string }) {
    const where = params.establishmentId ? { establishmentId: params.establishmentId } : {};
    const [products, lots, report] = await Promise.all([
      this.prisma.product.findMany({
        where,
        include: { category: true, lots: true },
        orderBy: { name: 'asc' },
      }),
      this.prisma.lot.findMany({
        where,
        include: { product: { select: { name: true, unit: true, code: true } } },
        orderBy: [{ expiryDate: 'asc' }, { createdAt: 'desc' }],
      }),
      this.reports.build({ establishmentId: params.establishmentId, period: 'mois' }),
    ]);
    const transfers = report.stock.transfers;
    const productRows = products.map((product) => {
      const qty = product.lots.reduce((sum, lot) => sum + lot.qtyCurrent, 0);
      const value = Math.round(product.lots.reduce((sum, lot) => sum + lot.qtyCurrent * lot.priceBuy, 0));
      return [
        product.code,
        product.name,
        product.category.name,
        product.kind,
        qty,
        product.unit,
        value,
        product.stockAlert,
        qty <= 0 ? 'Rupture' : qty <= product.stockAlert ? 'Bas' : 'OK',
      ];
    });
    const lotRows = lots.map((lot) => [
      lot.number,
      lot.product.code,
      lot.product.name,
      lot.qtyCurrent,
      lot.qtyInitial,
      lot.product.unit,
      lot.priceBuy,
      day(lot.entryDate),
      day(lot.expiryDate),
      lot.location,
      lot.status,
    ]);
    const sheets: ExcelSheet[] = [
      {
        name: 'Stock',
        headers: ['Code', 'Produit', 'Categorie', 'Type', 'Qte', 'Unite', 'Valeur FC', 'Seuil', 'Etat'],
        rows: productRows,
      },
      {
        name: 'Lots',
        headers: ['Lot', 'Code', 'Produit', 'Qte actuelle', 'Qte initiale', 'Unite', 'Achat FC', 'Entree', 'Peremption', 'Emplacement', 'Statut'],
        rows: lotRows,
      },
      {
        name: 'Transferts',
        headers: ['No', 'Statut', 'Produit', 'Qte', 'Unite', 'Source', 'Destination', 'Valeur FC', 'Expedie', 'Recu'],
        rows: (transfers?.lines ?? []).map((row: Record<string, unknown>) => [
          row.number,
          row.status,
          row.product,
          row.quantity,
          row.unit,
          row.source,
          row.dest,
          row.cost,
          day(row.shippedAt as string | null),
          day(row.receivedAt as string | null),
        ]),
      },
    ];
    return {
      sheets,
      doc: this.doc(
        'Etat du stock',
        params.site,
        [
          {
            title: 'Niveaux par produit',
            columns: [
              { header: 'Code', width: 60 },
              { header: 'Produit', width: 140 },
              { header: 'Categorie', width: 90 },
              { header: 'Qte', width: 50, align: 'right' },
              { header: 'Unite', width: 45 },
              { header: 'Valeur', width: 80, align: 'right' },
              { header: 'Etat', width: 50 },
            ],
            rows: productRows.map((row) => [row[0], row[1], row[2], row[4], row[5], fcPdf(row[6]), row[8]]),
          },
          {
            title: 'Lots FEFO',
            columns: [
              { header: 'Lot', width: 90 },
              { header: 'Produit', width: 140 },
              { header: 'Qte', width: 50, align: 'right' },
              { header: 'Achat', width: 70, align: 'right' },
              { header: 'Entree', width: 70 },
              { header: 'Peremption', width: 70 },
              { header: 'Emplacement', width: 80 },
            ],
            rows: lots.map((lot) => [
              lot.number,
              lot.product.name,
              lot.qtyCurrent,
              fcPdf(lot.priceBuy),
              day(lot.entryDate),
              day(lot.expiryDate),
              lot.location,
            ]),
          },
          {
            title: 'Transferts du mois',
            columns: [
              { header: 'No', width: 80 },
              { header: 'Statut', width: 70 },
              { header: 'Produit', width: 120 },
              { header: 'Qte', width: 50, align: 'right' },
              { header: 'Trajet', width: 160 },
              { header: 'Valeur', width: 70, align: 'right' },
            ],
            rows: (transfers?.lines ?? []).map((row: Record<string, unknown>) => [
              String(row.number ?? ''),
              String(row.status ?? ''),
              String(row.product ?? ''),
              String(row.quantity ?? ''),
              `${row.source ?? ''} → ${row.dest ?? ''}`,
              fcPdf(row.cost as number),
            ]),
            totals: [
              'TOTAL',
              '',
              `${transfers?.count ?? 0} trf`,
              String(transfers?.quantity ?? 0),
              '',
              fcPdf((transfers?.valueOut ?? 0) + (transfers?.valueIn ?? 0)),
            ],
          },
        ],
        {
          kpis: [
            { label: 'Produits', value: String(products.length) },
            { label: 'Transferts mois', value: String(transfers?.count ?? 0) },
            { label: 'A receptionner', value: String(transfers?.pendingReceive ?? 0) },
            { label: 'Trf sortis', value: fcPdf(transfers?.valueOut ?? 0), highlight: true },
          ],
          notes: ['Les transferts inter-sites apparaissent pour la transparence du mouvement de stock.'],
        },
      ),
    };
  }

  private async catalog(params: { establishmentId?: string; site: string }) {
    if (!params.establishmentId) {
      throw new BadRequestException('Choisissez un etablissement pour extraire le catalogue');
    }
    const products = await this.prisma.product.findMany({
      where: { establishmentId: params.establishmentId },
      include: {
        category: true,
        recipe: { include: { items: { include: { ingredient: true } } } },
      },
      orderBy: { name: 'asc' },
    });
    const rows = products.map((product) => [
      product.code,
      product.name,
      product.category.name,
      product.subcategory ?? '',
      product.kind,
      product.format ?? '',
      product.volume ?? '',
      product.unit,
      product.priceBuy,
      product.priceSell,
      product.status,
      product.recipe?.items.map((item) => `${item.ingredient.name} ${item.quantity}`).join(', ') ?? '',
    ]);
    const sheets: ExcelSheet[] = [
      {
        name: 'Catalogue',
        headers: ['Code', 'Nom', 'Categorie', 'Sous-cat.', 'Type', 'Format', 'Volume', 'Unite', 'Achat FC', 'Vente FC', 'Statut', 'Recette'],
        rows,
      },
    ];
    return {
      sheets,
      doc: this.doc('Catalogue produits', params.site, [
        {
          title: 'Fiches catalogue',
          columns: [
            { header: 'Code', width: 70 },
            { header: 'Nom', width: 130 },
            { header: 'Categorie', width: 80 },
            { header: 'Type', width: 60 },
            { header: 'Achat', width: 70, align: 'right' },
            { header: 'Vente', width: 70, align: 'right' },
            { header: 'Statut', width: 50 },
          ],
          rows: products.map((product) => [
            product.code,
            product.name,
            product.category.name,
            product.kind,
            fcPdf(product.priceBuy),
            fcPdf(product.priceSell),
            product.status,
          ]),
        },
      ]),
    };
  }

  private async sales(params: {
    establishmentId?: string;
    period?: string;
    from?: string;
    to?: string;
    site: string;
  }) {
    const { from, to, period } = this.reports.range(params.period, params.from, params.to);
    const [orders, report] = await Promise.all([
      this.prisma.order.findMany({
        where: {
          ...(params.establishmentId ? { establishmentId: params.establishmentId } : {}),
          createdAt: { gte: from, lte: to },
        },
        include: {
          items: true,
          user: { select: { name: true } },
          establishment: { select: { name: true } },
        },
        orderBy: { createdAt: 'asc' },
      }),
      this.reports.build(params),
    ]);
    const transfers = report.stock.transfers;
    const orderRows = orders.map((order) => [
      order.number,
      day(order.createdAt),
      order.establishment.name,
      order.type,
      order.status,
      order.paymentStatus,
      order.customerName ?? '',
      order.total,
      order.user?.name ?? '',
    ]);
    const lineRows = orders.flatMap((order) =>
      order.items.map((item) => [
        order.number,
        day(order.createdAt),
        item.name,
        item.quantity,
        item.unitPrice,
        item.lineTotal,
      ]),
    );
    const transferRows = (transfers?.lines ?? []).map((row: Record<string, unknown>) => [
      row.number,
      day(row.createdAt as string | null),
      row.status,
      row.product,
      row.quantity,
      row.unit,
      row.source,
      row.dest,
      row.cost,
      day(row.shippedAt as string | null),
      day(row.receivedAt as string | null),
    ]);
    const sheets: ExcelSheet[] = [
      {
        name: 'Ventes',
        headers: ['Commande', 'Date', 'Etablissement', 'Type', 'Statut', 'Paiement', 'Client', 'Total FC', 'Caissier'],
        rows: orderRows,
      },
      {
        name: 'Lignes',
        headers: ['Commande', 'Date', 'Produit', 'Qte', 'Prix FC', 'Ligne FC'],
        rows: lineRows,
      },
      {
        name: 'Transferts',
        headers: ['No', 'Date', 'Statut', 'Produit', 'Qte', 'Unite', 'Source', 'Destination', 'Valeur FC', 'Expedie', 'Recu'],
        rows: transferRows,
      },
    ];
    const total = orders.reduce((sum, order) => sum + order.total, 0);
    return {
      sheets,
      doc: this.doc(
        'Journal des ventes',
        params.site,
        [
          {
            title: 'Commandes',
            columns: [
              { header: 'No', width: 90 },
              { header: 'Date', width: 70 },
              { header: 'Type', width: 70 },
              { header: 'Statut', width: 70 },
              { header: 'Paiement', width: 70 },
              { header: 'Client', width: 80 },
              { header: 'Total', width: 70, align: 'right' },
            ],
            rows: orders.map((order) => [
              order.number,
              day(order.createdAt),
              order.type,
              order.status,
              order.paymentStatus,
              order.customerName ?? '',
              fcPdf(order.total),
            ]),
            totals: ['TOTAL', '', '', '', '', `${orders.length} cmd`, fcPdf(total)],
          },
          {
            title: 'Transferts inter-sites',
            columns: [
              { header: 'No', width: 80 },
              { header: 'Statut', width: 70 },
              { header: 'Produit', width: 120 },
              { header: 'Qte', width: 50, align: 'right' },
              { header: 'Trajet', width: 160 },
              { header: 'Valeur', width: 70, align: 'right' },
            ],
            rows: (transfers?.lines ?? []).map((row: Record<string, unknown>) => [
              String(row.number ?? ''),
              String(row.status ?? ''),
              String(row.product ?? ''),
              String(row.quantity ?? ''),
              `${row.source ?? ''} → ${row.dest ?? ''}`,
              fcPdf(row.cost as number),
            ]),
            totals: [
              'TOTAL',
              '',
              `${transfers?.count ?? 0} trf`,
              String(transfers?.quantity ?? 0),
              '',
              fcPdf((transfers?.valueOut ?? 0) + (transfers?.valueIn ?? 0)),
            ],
          },
        ],
        {
          period,
          range: `${day(from)} → ${day(to)}`,
          kpis: [
            { label: 'Commandes', value: String(orders.length) },
            { label: 'Chiffre d affaires', value: fcPdf(total), highlight: true },
            { label: 'Transferts', value: String(transfers?.count ?? 0) },
            { label: 'Trf sortis', value: fcPdf(transfers?.valueOut ?? 0) },
          ],
          notes: [
            'Les transferts inter-sites sont un journal de stock (hors chiffre d affaires).',
          ],
        },
      ),
    };
  }

  private async report(params: {
    establishmentId?: string;
    period?: string;
    from?: string;
    to?: string;
    site: string;
  }) {
    const data = await this.reports.build(params);
    const sales = data.sales;
    const finance = data.finance;
    const stock = data.stock as {
      kitchenExtraCost?: number;
      kitchenCost?: number;
      kitchenExits?: Array<Record<string, unknown>>;
      transfers?: {
        count: number;
        quantity: number;
        valueOut: number;
        valueIn: number;
        pendingReceive: number;
        lines: Array<Record<string, unknown>>;
        bySite: Array<Record<string, unknown>>;
        byDay: Array<Record<string, unknown>>;
        movements: Array<Record<string, unknown>>;
      };
    };
    const transfers = stock.transfers ?? {
      count: 0,
      quantity: 0,
      valueOut: 0,
      valueIn: 0,
      pendingReceive: 0,
      lines: [],
      bySite: [],
      byDay: [],
      movements: [],
    };
    const sheets: ExcelSheet[] = [
      {
        name: 'Synthese',
        headers: ['Indicateur', 'Montant FC'],
        rows: [
          ['CA brut avant remise', finance.grossRevenue],
          ['Remises accordees', finance.discounts],
          ['Chiffre d affaires net', finance.revenue],
          ['CA paye', finance.paidRevenue],
          ['Depense produits', finance.productExpense],
          ['Pertes valorisees', finance.lossValue],
          ['Sorties magasin cuisine', stock.kitchenExtraCost ?? 0],
          ['Transferts sortis valeur', transfers.valueOut],
          ['Transferts recus valeur', transfers.valueIn],
          ['Nb transferts', transfers.count],
          ['Transferts a receptionner', transfers.pendingReceive],
          ['Total benefice', finance.profit],
          ['Commandes', sales.orders],
          ['Payees', sales.paid],
        ],
      },
      {
        name: 'Remises',
        headers: ['Motif', 'Nb', 'Montant FC'],
        rows: (finance.discountsByMotif ?? []).map((row: { motif: string; count: number; amount: number }) => [
          row.motif,
          row.count,
          row.amount,
        ]),
      },
      {
        name: 'Transferts',
        headers: ['No', 'Statut', 'Produit', 'Qte', 'Unite', 'Source', 'Destination', 'Valeur FC', 'Expedie', 'Recu'],
        rows: transfers.lines.map((row) => [
          row.number,
          row.status,
          row.product,
          row.quantity,
          row.unit,
          row.source,
          row.dest,
          row.cost,
          day(row.shippedAt as string | null),
          day(row.receivedAt as string | null),
        ]),
      },
      {
        name: 'Transferts trajets',
        headers: ['Trajet', 'Nb sortis', 'Qte', 'Valeur sortie FC', 'Nb recus', 'Valeur recue FC'],
        rows: transfers.bySite.map((row) => [
          row.name,
          row.outCount,
          row.outQty,
          row.outValue,
          row.inCount,
          row.inValue,
        ]),
      },
      {
        name: 'Sorties cuisine',
        headers: ['Heure', 'Produit', 'Lot', 'Qte', 'Cout FC', 'Type'],
        rows: (stock.kitchenExits ?? []).map((row) => [
          day(row.createdAt as string | null),
          row.product,
          row.lot,
          row.quantity,
          row.cost,
          row.type,
        ]),
      },
      {
        name: 'Par produit',
        headers: ['Produit', 'Qte', 'CA FC', 'Depense FC', 'Benefice FC'],
        rows: sales.byProduct.map((row) => [row.name, row.qty, row.revenue, row.expense, row.profit]),
      },
      {
        name: 'Par categorie',
        headers: ['Categorie', 'CA FC', 'Depense FC', 'Benefice FC'],
        rows: sales.byCategory.map((row) => [row.name, row.revenue, row.expense, row.profit]),
      },
      {
        name: 'Par jour',
        headers: ['Date', 'CA FC'],
        rows: sales.byDay.map((row) => [row.date, row.total]),
      },
    ];
    const byProductRows = sales.byProduct.map((row) => [
      row.name,
      row.qty,
      fcPdf(row.revenue),
      fcPdf(row.expense),
      fcPdf(row.profit),
    ]);
    const byCategoryRows = sales.byCategory.map((row) => [
      row.name,
      fcPdf(row.revenue),
      fcPdf(row.expense),
      fcPdf(row.profit),
    ]);
    const transferRows = transfers.lines.map((row) => [
      String(row.number ?? ''),
      String(row.status ?? ''),
      String(row.product ?? ''),
      String(row.quantity ?? ''),
      `${row.source ?? ''} → ${row.dest ?? ''}`,
      fcPdf(row.cost as number),
    ]);
    return {
      sheets,
      doc: this.doc(
        'Rapport d activite',
        params.site,
        [
          {
            title: 'Synthese financiere',
            columns: [
              { header: 'Indicateur', width: 320 },
              { header: 'Montant', width: 200, align: 'right' },
            ],
            rows: [
              ['CA brut avant remise', fcPdf(finance.grossRevenue)],
              ['Remises accordees', fcPdf(finance.discounts)],
              ['Chiffre d affaires net', fcPdf(finance.revenue)],
              ['CA encaisse', fcPdf(finance.paidRevenue)],
              ['Depense produits vendus', fcPdf(finance.productExpense)],
              ['Pertes valorisees', fcPdf(finance.lossValue)],
              ['Sorties magasin → cuisine', fcPdf(stock.kitchenExtraCost ?? 0)],
              ['Transferts sortis (valeur)', fcPdf(transfers.valueOut)],
              ['Transferts recus (valeur)', fcPdf(transfers.valueIn)],
            ],
            totals: ['Total benefice', fcPdf(finance.profit)],
          },
          {
            title: 'Transferts inter-sites',
            columns: [
              { header: 'No', width: 80 },
              { header: 'Statut', width: 70 },
              { header: 'Produit', width: 120 },
              { header: 'Qte', width: 50, align: 'right' },
              { header: 'Trajet', width: 160 },
              { header: 'Valeur', width: 70, align: 'right' },
            ],
            rows: transferRows,
            totals: [
              'TOTAL',
              '',
              `${transfers.count} trf`,
              String(transfers.quantity),
              '',
              fcPdf(transfers.valueOut + transfers.valueIn),
            ],
          },
          this.moneyTable(
            'Ventes par produit',
            ['Produit', 'Qte', 'CA', 'Depense', 'Benefice'],
            byProductRows,
            ['TOTAL', '', fcPdf(sales.byProduct.reduce((sum, row) => sum + row.revenue, 0)), fcPdf(sales.byProduct.reduce((sum, row) => sum + (row.expense ?? 0), 0)), fcPdf(sales.profit)],
            1,
          ),
          this.moneyTable(
            'Ventes par categorie',
            ['Categorie', 'CA', 'Depense', 'Benefice'],
            byCategoryRows,
            undefined,
            1,
          ),
          {
            title: 'Ventes par jour',
            columns: [
              { header: 'Date', width: 200 },
              { header: 'Chiffre d affaires', width: 320, align: 'right' },
            ],
            rows: sales.byDay.map((row) => [row.date, fcPdf(row.total)]),
          },
        ],
        {
          period: data.period,
          range: `${day(data.from)} → ${day(data.to)}`,
          kpis: [
            { label: 'Commandes', value: String(sales.orders) },
            { label: 'CA net', value: fcPdf(finance.revenue) },
            { label: 'Transferts', value: String(transfers.count) },
            { label: 'Trf sortis', value: fcPdf(transfers.valueOut) },
            { label: 'Total benefice', value: fcPdf(finance.profit), highlight: true },
          ],
          notes: [
            'CA net = apres remises. CA brut et remises sont separes pour la transparence.',
            'Transferts et sorties magasin→cuisine = journal stock (hors benefice).',
            'Le prix de vente catalogue ne change pas. La depense et le benefice suivent le prix d achat de chaque lot sorti (FEFO).',
            'Document genere pour l etablissement selectionne. Usage interne IPIP SARLU / NDJO TACOS.',
          ],
        },
      ),
    };
  }
}
