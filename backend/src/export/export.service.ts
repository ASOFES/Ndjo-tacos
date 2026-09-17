import { BadRequestException, Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { ReportsService } from '../reports/reports.service';
import { companyPdfLines } from '../invoices/company';
import { ExcelSheet, buildExcel } from './excel';
import { buildPdf } from './pdf';

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
        buffer: buildPdf(built.pdf),
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

  private header(title: string, site: string, extra: string[] = []) {
    return [...companyPdfLines(), '', title, `Etablissement : ${site}`, `Date : ${stamp()}`, ...extra, ''];
  }

  private async stock(params: { establishmentId?: string; site: string }) {
    const where = params.establishmentId ? { establishmentId: params.establishmentId } : {};
    const products = await this.prisma.product.findMany({
      where,
      include: { category: true, lots: true },
      orderBy: { name: 'asc' },
    });
    const lots = await this.prisma.lot.findMany({
      where,
      include: { product: { select: { name: true, unit: true, code: true } } },
      orderBy: [{ expiryDate: 'asc' }, { createdAt: 'desc' }],
    });
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
    ];
    const pdf = [
      ...this.header('Extraction stock', params.site),
      'PRODUITS',
      ...productRows.map((row) => row.join(' | ')),
      '',
      'LOTS',
      ...lotRows.map((row) => row.join(' | ')),
    ];
    return { sheets, pdf };
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
    const pdf = [
      ...this.header('Extraction catalogue', params.site),
      ...rows.map((row) => `${row[0]} | ${row[1]} | ${row[2]} | ${row[4]} | achat ${row[8]} | vente ${row[9]} | ${row[11]}`),
    ];
    return { sheets, pdf };
  }

  private async sales(params: {
    establishmentId?: string;
    period?: string;
    from?: string;
    to?: string;
    site: string;
  }) {
    const { from, to, period } = this.reports.range(params.period, params.from, params.to);
    const orders = await this.prisma.order.findMany({
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
    });
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
    ];
    const pdf = [
      ...this.header('Extraction ventes', params.site, [
        `Periode : ${period}`,
        `Du ${day(from)} au ${day(to)}`,
        `Commandes : ${orders.length}`,
        `Total : ${orders.reduce((sum, order) => sum + order.total, 0)} FC`,
      ]),
      ...orderRows.map((row) => `${row[0]} | ${row[1]} | ${row[3]} | ${row[4]} | ${row[5]} | ${row[7]} FC`),
    ];
    return { sheets, pdf };
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
    const sheets: ExcelSheet[] = [
      {
        name: 'Synthese',
        headers: ['Indicateur', 'Montant FC'],
        rows: [
          ['Chiffre d affaires ventes', finance.revenue],
          ['CA paye', finance.paidRevenue],
          ['Depense produits', finance.productExpense],
          ['Pertes valorisees', finance.lossValue],
          ['Total benefice', finance.profit],
          ['Commandes', sales.orders],
          ['Payees', sales.paid],
        ],
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
    const pdf = [
      ...this.header('Rapport NDJO TACOS', params.site, [
        `Periode : ${data.period}`,
        `Du ${day(data.from)} au ${day(data.to)}`,
        `CA : ${finance.revenue} FC`,
        `Depense produits : ${finance.productExpense} FC`,
        `Total benefice : ${finance.profit} FC`,
      ]),
      'PAR PRODUIT',
      ...sales.byProduct.map(
        (row) => `${row.name} | qte ${row.qty} | CA ${row.revenue} | depense ${row.expense} | benefice ${row.profit}`,
      ),
      '',
      'PAR CATEGORIE',
      ...sales.byCategory.map(
        (row) => `${row.name} | CA ${row.revenue} | depense ${row.expense} | benefice ${row.profit}`,
      ),
    ];
    return { sheets, pdf };
  }
}
