import { COMPANY } from '../invoices/company';

export function pdfSafe(text: unknown) {
  return String(text ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[’‘]/g, "'")
    .replace(/[–—]/g, '-')
    .replace(/[^\x09\x0a\x0d\x20-\x7e]/g, ' ');
}

function escapePdf(text: string) {
  return pdfSafe(text).replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

export function fcPdf(value: unknown) {
  const amount = Math.round(Number(value) || 0);
  const digits = String(Math.abs(amount));
  const grouped = digits.replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  return `${amount < 0 ? '-' : ''}${grouped} FC`;
}

export type PdfColumn = { header: string; width: number; align?: 'left' | 'right' };
export type PdfKpi = { label: string; value: string; highlight?: boolean };
export type PdfTable = {
  title: string;
  columns: PdfColumn[];
  rows: unknown[][];
  totals?: unknown[];
};
export type PdfDocument = {
  title: string;
  site: string;
  period?: string;
  range?: string;
  kpis?: PdfKpi[];
  tables: PdfTable[];
  notes?: string[];
};

const PAGE_W = 595;
const PAGE_H = 842;
const MARGIN = 36;
const CONTENT_W = PAGE_W - MARGIN * 2;

const ORANGE = '0.910 0.365 0.016';
const ACCENT = '0.957 0.549 0.024';
const INK = '0.122 0.098 0.082';
const MUTED = '0.420 0.365 0.322';
const LINE = '0.859 0.808 0.757';
const CREAM = '0.996 0.973 0.941';
const WHITE = '1 1 1';

type Page = { ops: string[] };

function rgb(color: string, fill = true) {
  return `${color} ${fill ? 'rg' : 'RG'}`;
}

function rect(x: number, y: number, w: number, h: number, fill?: string, stroke?: string) {
  const ops: string[] = [];
  if (fill) ops.push(`${rgb(fill)} ${x.toFixed(2)} ${y.toFixed(2)} ${w.toFixed(2)} ${h.toFixed(2)} re f`);
  if (stroke) ops.push(`${rgb(stroke, false)} 0.4 w ${x.toFixed(2)} ${y.toFixed(2)} ${w.toFixed(2)} ${h.toFixed(2)} re S`);
  return ops.join('\n');
}

function text(
  value: unknown,
  x: number,
  y: number,
  size: number,
  bold = false,
  color = INK,
  align: 'left' | 'right' = 'left',
  maxWidth?: number,
) {
  let raw = pdfSafe(value);
  if (maxWidth) {
    const maxChars = Math.max(4, Math.floor(maxWidth / (size * 0.5)));
    if (raw.length > maxChars) raw = `${raw.slice(0, maxChars - 1)}.`;
  }
  const width = raw.length * size * 0.5;
  const tx = align === 'right' ? x - width : x;
  const font = bold ? 'F2' : 'F1';
  return `${rgb(color)} BT /${font} ${size} Tf ${tx.toFixed(2)} ${y.toFixed(2)} Td (${escapePdf(raw)}) Tj ET`;
}

function assemble(pages: Page[]) {
  const objects: string[] = [
    '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj',
  ];
  const pageIds: number[] = [];
  const contentIds: number[] = [];
  let nextId = 5;
  for (let i = 0; i < pages.length; i += 1) {
    pageIds.push(nextId);
    contentIds.push(nextId + 1);
    nextId += 2;
  }
  objects.push(
    `2 0 obj << /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(' ')}] /Count ${pages.length} >> endobj`,
  );
  objects.push('3 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj');
  objects.push('4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >> endobj');
  pages.forEach((page, index) => {
    const content = page.ops.join('\n');
    objects.push(
      `${pageIds[index]} 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 ${PAGE_W} ${PAGE_H}] /Contents ${contentIds[index]} 0 R /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> >> endobj`,
    );
    objects.push(
      `${contentIds[index]} 0 obj << /Length ${Buffer.byteLength(content)} >> stream\n${content}\nendstream endobj`,
    );
  });
  let offset = 9;
  const xref = ['0000000000 65535 f '];
  const chunks = ['%PDF-1.4\n'];
  for (const object of objects) {
    xref.push(`${String(offset).padStart(10, '0')} 00000 n `);
    chunks.push(`${object}\n`);
    offset += Buffer.byteLength(`${object}\n`);
  }
  chunks.push(`xref\n0 ${objects.length + 1}\n${xref.join('\n')}\n`);
  chunks.push(
    `trailer << /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${offset}\n%%EOF`,
  );
  return Buffer.from(chunks.join(''));
}

function letterhead(ops: string[], compact: boolean) {
  ops.push(rect(0, PAGE_H - 56, PAGE_W, 56, ORANGE));
  ops.push(text(COMPANY.brand, MARGIN, PAGE_H - 28, 16, true, WHITE));
  ops.push(text('IPIP SARLU  ·  Lubumbashi', PAGE_W - MARGIN, PAGE_H - 28, 9, false, WHITE, 'right'));
  ops.push(rect(0, PAGE_H - 60, PAGE_W, 4, ACCENT));
  if (compact) return PAGE_H - 78;
  ops.push(text(COMPANY.legalName, MARGIN, PAGE_H - 76, 8, true, INK, 'left', CONTENT_W));
  ops.push(text(COMPANY.address, MARGIN, PAGE_H - 88, 8, false, MUTED, 'left', CONTENT_W));
  ops.push(
    text(
      `RCCM ${COMPANY.rccm}   ·   ID. NAT. ${COMPANY.idNat}   ·   NIF ${COMPANY.nif}   ·   ${COMPANY.phone}`,
      MARGIN,
      PAGE_H - 100,
      7.5,
      false,
      MUTED,
      'left',
      CONTENT_W,
    ),
  );
  return PAGE_H - 118;
}

function footer(ops: string[], page: number, total: number) {
  ops.push(rect(MARGIN, 24, CONTENT_W, 0.6, undefined, LINE));
  ops.push(text('Document interne NDJO TACOS — extraction officielle', MARGIN, 14, 7, false, MUTED));
  ops.push(text(`Page ${page} / ${total}`, PAGE_W - MARGIN, 14, 7, false, MUTED, 'right'));
}

export function buildPremiumPdf(doc: PdfDocument) {
  const pages: Page[] = [];
  let page: Page = { ops: [] };
  let y = letterhead(page.ops, false);
  const startBody = () => {
    pages.push(page);
    page = { ops: [] };
    y = letterhead(page.ops, true);
  };

  page.ops.push(text(doc.title, MARGIN, y, 18, true, INK));
  y -= 16;
  page.ops.push(text(doc.site, MARGIN, y, 10, true, ORANGE));
  y -= 13;
  if (doc.period || doc.range) {
    page.ops.push(text([doc.period, doc.range].filter(Boolean).join('  ·  '), MARGIN, y, 9, false, MUTED));
    y -= 18;
  } else {
    y -= 8;
  }

  if (doc.kpis?.length) {
    const gap = 8;
    const count = Math.min(4, doc.kpis.length);
    const cardW = (CONTENT_W - gap * (count - 1)) / count;
    const cardH = 46;
    if (y - cardH < 60) startBody();
    doc.kpis.slice(0, 4).forEach((kpi, index) => {
      const x = MARGIN + index * (cardW + gap);
      const fill = kpi.highlight ? ORANGE : CREAM;
      const labelColor = kpi.highlight ? WHITE : MUTED;
      const valueColor = kpi.highlight ? WHITE : INK;
      page.ops.push(rect(x, y - cardH, cardW, cardH, fill, kpi.highlight ? undefined : LINE));
      page.ops.push(text(kpi.label, x + 8, y - 16, 7, false, labelColor, 'left', cardW - 16));
      page.ops.push(text(kpi.value, x + 8, y - 34, 11, true, valueColor, 'left', cardW - 16));
    });
    y -= cardH + 18;
  }

  const drawTable = (table: PdfTable) => {
    const rowH = 16;
    const headH = 18;
    const colW = table.columns.map((column) => column.width);
    const tableW = colW.reduce((sum, width) => sum + width, 0);
    const scale = tableW > CONTENT_W ? CONTENT_W / tableW : 1;
    const widths = colW.map((width) => width * scale);

    const need = (rows: number) => headH + 22 + rows * rowH;
    if (y - need(1) < 56) startBody();
    page.ops.push(text(table.title, MARGIN, y, 11, true, INK));
    y -= 8;
    page.ops.push(rect(MARGIN, y, CONTENT_W, 1.2, ORANGE));
    y -= 6;

    const drawHeader = () => {
      page.ops.push(rect(MARGIN, y - headH, CONTENT_W, headH, ORANGE));
      let x = MARGIN;
      table.columns.forEach((column, index) => {
        const w = widths[index];
        const tx = column.align === 'right' ? x + w - 6 : x + 6;
        page.ops.push(text(column.header, tx, y - 12, 7.5, true, WHITE, column.align, w - 10));
        x += w;
      });
      y -= headH;
    };

    drawHeader();
    const body = [...table.rows.map((row) => row.map((cell) => cell)), ...(table.totals ? [table.totals] : [])];
    body.forEach((row, rowIndex) => {
      if (y - rowH < 48) {
        startBody();
        page.ops.push(text(`${table.title} (suite)`, MARGIN, y, 10, true, INK));
        y -= 14;
        drawHeader();
      }
      const isTotal = Boolean(table.totals) && rowIndex === body.length - 1;
      page.ops.push(rect(MARGIN, y - rowH, CONTENT_W, rowH, isTotal ? ACCENT : rowIndex % 2 === 0 ? WHITE : CREAM));
      let x = MARGIN;
      table.columns.forEach((column, index) => {
        const w = widths[index];
        const tx = column.align === 'right' ? x + w - 6 : x + 6;
        const value = row[index] ?? '';
        page.ops.push(
          text(value, tx, y - 11, isTotal ? 7.5 : 7.5, isTotal, isTotal ? WHITE : INK, column.align, w - 10),
        );
        x += w;
      });
      y -= rowH;
    });
    if (!body.length) {
      page.ops.push(text('Aucune donnee sur cette periode.', MARGIN + 6, y - 12, 8, false, MUTED));
      y -= 18;
    }
    y -= 16;
  };

  for (const table of doc.tables) drawTable(table);

  if (doc.notes?.length) {
    if (y < 80) startBody();
    page.ops.push(text('Note', MARGIN, y, 9, true, MUTED));
    y -= 12;
    for (const note of doc.notes) {
      page.ops.push(text(note, MARGIN, y, 8, false, MUTED, 'left', CONTENT_W));
      y -= 11;
    }
  }

  pages.push(page);
  pages.forEach((item, index) => footer(item.ops, index + 1, pages.length));
  return assemble(pages);
}

export function buildPdf(lines: string[]) {
  return buildPremiumPdf({
    title: 'Extraction NDJO TACOS',
    site: COMPANY.brand,
    tables: [
      {
        title: 'Contenu',
        columns: [{ header: 'Ligne', width: CONTENT_W }],
        rows: lines.map((line) => [line]),
      },
    ],
  });
}
