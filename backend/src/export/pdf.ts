function escapePdf(text: string) {
  return text.replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

export function pdfSafe(text: unknown) {
  return String(text ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[’‘]/g, "'")
    .replace(/[–—]/g, '-')
    .replace(/[^\x09\x0a\x0d\x20-\x7e]/g, ' ');
}

export function buildPdf(lines: string[]) {
  const safe = lines.map(pdfSafe);
  const perPage = 42;
  const pages: string[][] = [];
  for (let i = 0; i < safe.length; i += perPage) {
    pages.push(safe.slice(i, i + perPage));
  }
  if (!pages.length) pages.push(['(vide)']);

  const objects: string[] = [];
  objects.push('1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj');
  const pageIds: number[] = [];
  const contentIds: number[] = [];
  let nextId = 4;
  for (let i = 0; i < pages.length; i += 1) {
    pageIds.push(nextId);
    contentIds.push(nextId + 1);
    nextId += 2;
  }
  objects.push(
    `2 0 obj << /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(' ')}] /Count ${pages.length} >> endobj`,
  );
  objects.push('3 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj');
  pages.forEach((pageLines, index) => {
    const content = pageLines
      .map((line, lineIndex) => `BT /F1 11 Tf 40 ${800 - lineIndex * 18} Td (${escapePdf(line)}) Tj ET`)
      .join('\n');
    const pageId = pageIds[index];
    const contentId = contentIds[index];
    objects.push(
      `${pageId} 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents ${contentId} 0 R /Resources << /Font << /F1 3 0 R >> >> >> endobj`,
    );
    objects.push(
      `${contentId} 0 obj << /Length ${Buffer.byteLength(content)} >> stream\n${content}\nendstream endobj`,
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
  const xrefStart = offset;
  chunks.push(`xref\n0 ${objects.length + 1}\n${xref.join('\n')}\n`);
  chunks.push(
    `trailer << /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xrefStart}\n%%EOF`,
  );
  return Buffer.from(chunks.join(''));
}
