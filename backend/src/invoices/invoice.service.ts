import { Injectable } from '@nestjs/common';
import { createHash, randomUUID } from 'crypto';
import { mkdirSync, writeFileSync } from 'fs';
import { join } from 'path';
import { PrismaService } from '../prisma.service';
import { StockService } from '../stock/stock.service';
import { companyPdfLines } from './company';
import { pdfSafe } from '../export/pdf';
import { isDrinkProduct } from '../orders/orders.service';

function escapePdf(text: string) {
  return pdfSafe(text).replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

function buildPdf(lines: string[]) {
  const content = lines
    .map((line, index) => `BT /F1 12 Tf 48 ${780 - index * 18} Td (${escapePdf(line)}) Tj ET`)
    .join('\n');
  const objects = [
    '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj',
    '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj',
    `3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj`,
    `4 0 obj << /Length ${Buffer.byteLength(content)} >> stream\n${content}\nendstream endobj`,
    '5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj',
  ];
  let offset = 9;
  const xref = ['0000000000 65535 f '];
  const chunks = ['%PDF-1.4\n'];
  for (const object of objects) {
    xref.push(`${String(offset).padStart(10, '0')} 00000 n `);
    chunks.push(`${object}\n`);
    offset += Buffer.byteLength(`${object}\n`);
  }
  const xrefStart = offset;
  chunks.push(`xref\n0 ${objects.length + 1}\n${xref.join('\n')}\n`);
  chunks.push(
    `trailer << /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xrefStart}\n%%EOF`,
  );
  return Buffer.from(chunks.join(''));
}

@Injectable()
export class InvoiceService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly stock: StockService,
  ) {}

  async issueForOrder(orderId: string) {
    const order = await this.prisma.order.findUnique({
      where: { id: orderId },
      include: {
        items: true,
        establishment: true,
        customer: { select: { name: true, phone: true } },
      },
    });
    if (!order) return null;
    const existing = await this.prisma.invoice.findUnique({ where: { orderId } });
    const products = await this.prisma.product.findMany({
      where: { id: { in: order.items.map((item) => item.productId) } },
      include: { category: true },
    });
    const drinkIds = new Set(products.filter((row) => isDrinkProduct(row)).map((row) => row.id));
    const kitchen = order.items.filter((item) => !drinkIds.has(item.productId));
    const drinks = order.items.filter((item) => drinkIds.has(item.productId));
    const lineOf = (item: (typeof order.items)[number]) =>
      `${item.quantity} x ${item.name}  ${item.lineTotal} FC`;

    const verifyToken =
      existing?.verifyToken ??
      createHash('sha256')
        .update(`${order.id}:${randomUUID()}`)
        .digest('hex')
        .slice(0, 24);
    const publicBase = process.env.PUBLIC_BASE_URL ?? 'http://localhost:3000';
    const verifyUrl = `${publicBase}/invoices/verify/${verifyToken}`;
    const content = [
      ...companyPdfLines(),
      '',
      `Etablissement : ${order.establishment.name}`,
      `Facture ${existing?.number ?? order.number}`,
      `Commande ${order.number}`,
      `Client : ${order.customerName ?? order.customer?.name ?? '-'}`,
      ...(kitchen.length
        ? ['Nourriture :', ...kitchen.map(lineOf)]
        : []),
      ...(drinks.length
        ? ['Boissons (interne) :', ...drinks.map(lineOf)]
        : !kitchen.length
          ? order.items.map(lineOf)
          : []),
      `Sous-total : ${order.subtotal || order.total} FC`,
      ...(order.discountAmount > 0
        ? [
            `Remise ${order.discountPercent}% (${order.discountMotif ?? '-'}) : -${order.discountAmount} FC`,
          ]
        : []),
      ...(order.deliveryFee > 0 ? [`Livraison : ${order.deliveryFee} FC`] : []),
      `Total net : ${order.total} FC`,
      `Paiement : ${order.paymentStatus}`,
      `Verifier : ${verifyUrl}`,
    ].join('\n');
    const pdf = buildPdf(content.split('\n'));
    const dir = join(process.cwd(), 'storage', 'invoices');
    mkdirSync(dir, { recursive: true });
    const fileName = `${order.number.replace(/[^A-Z0-9-]/gi, '_')}.pdf`;
    const pdfPath = join(dir, fileName);
    writeFileSync(pdfPath, pdf);

    const number =
      existing?.number ?? (await this.stock.nextNumber(this.prisma, 'FAC'));
    return this.prisma.invoice.upsert({
      where: { orderId },
      update: {
        content,
        total: order.total,
        pdfPath,
        verifyToken,
        qrPayload: verifyUrl,
      },
      create: {
        number,
        orderId,
        total: order.total,
        content,
        pdfPath,
        verifyToken,
        qrPayload: verifyUrl,
      },
    });
  }
}
